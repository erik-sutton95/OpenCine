import Foundation
import OpenCineAppKit
import Testing

@MainActor private final class PresentationGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiting.count }
    func wait() async { await withCheckedContinuation { waiting.append($0) } }
    func release() { waiting.removeFirst().resume() }
}

/// SIMULATED native/external priority and captured cleanup, with manual completion ports.
@MainActor @Suite struct MonitorDeliveryPresentationTests {
    typealias Owner = MonitorDeliveryPresentation<String>

    private func owner() -> Owner {
        Owner(
            isCaching: { $0.hasPrefix("cache:") },
            isExternalDelivery: { $0.hasPrefix("upload:") },
            sleep: { _ in throw CancellationError() })
    }

    @Test func lateExternalFinallyCannotClearSuccessorProgress() async {
        let owner = owner()
        var cancelled: [String] = []
        let old = owner.trackExternalDelivery(
            operation: .init(active: { true }, cancel: { cancelled.append("old") }))
        owner.publishCache(old, progress: "cache:old")
        await settle { owner.overlayState == "cache:old" }
        let successor = owner.trackExternalDelivery(
            operation: .init(active: { true }, cancel: { cancelled.append("successor") }))
        owner.publishCache(successor, progress: "cache:successor")
        await settle { owner.overlayState == "cache:successor" }
        owner.finishExternalDelivery(old)
        owner.completeExternalDelivery(old, message: "old toast")
        owner.publishCache(old, progress: "cache:late")
        owner.noteExternalIdle(old)
        #expect(owner.overlayState == "cache:successor" && owner.completionToast == nil)
        #expect(cancelled.isEmpty)
        owner.cancel()
        #expect(cancelled == ["successor"] && owner.overlayState == nil)
        owner.close()
    }

    @Test func currentCancellationReachesTheCapturedNativeAndExternalOperations() async throws {
        let owner = owner()
        let entered = PresentationGate()
        var nativeAdmission: MonitorDeliveryAdmission?
        var cancellations = 0
        let external = owner.trackExternalDelivery(
            operation: .init(active: { true }, cancel: { cancellations += 1 }))
        let started = owner.beginNativeCaptured { report, admission in
            nativeAdmission = admission
            report("native")
            await entered.wait()
            report("late native")
            return "late toast"
        }
        let handle = try #require(started)
        await settle { entered.count == 1 }
        #expect(nativeAdmission?.isCurrent() == true && owner.nativeRunning)
        owner.cancel()
        #expect(cancellations == 1 && nativeAdmission?.isCurrent() == false)
        #expect(!owner.nativeRunning && owner.overlayState == nil)
        owner.publishCache(external, progress: "cache:retired")
        entered.release()
        await handle.awaitEnteredCleanup()
        #expect(owner.overlayState == nil && owner.completionToast == nil)
        owner.close()
        #expect(cancellations == 1)
    }

    @Test func cancelCallbackCannotRetireAReentrantSuccessor() async {
        let owner = owner()
        var successor: MonitorDeliveryExternalTicket<String>?
        var cancelled: [String] = []
        _ = owner.trackExternalDelivery(
            operation: .init(
                active: { true },
                cancel: {
                    cancelled.append("old")
                    successor = owner.trackExternalDelivery(
                        operation: .init(
                            active: { true }, cancel: { cancelled.append("successor") }))
                    owner.publishCache(successor!, progress: "cache:reentrant")
                }))
        await settle { !owner.nativeRunning }
        owner.cancel()
        await settle { owner.overlayState == "cache:reentrant" }
        #expect(cancelled == ["old"] && successor != nil)
        owner.close()
        #expect(cancelled == ["old", "successor"])
    }

    @Test func capturedNativeHandleJoinsEnteredCleanupWithoutSuccessorPublication() async throws {
        let owner = owner()
        let entered = PresentationGate()
        let cleanup = PresentationGate()
        let successor = PresentationGate()
        var joined = false
        let started = owner.beginNativeCaptured { report, _ in
            report("old")
            await entered.wait()
            await cleanup.wait()
            report("late old")
            return "old toast"
        }
        let old = try #require(started)
        await settle { entered.count == 1 }
        let waiter = Task {
            await old.cancelAndJoin()
            joined = true
        }
        await settle { !owner.nativeRunning }
        owner.beginNative { report in
            report("successor")
            await successor.wait()
            return "successor toast"
        }
        await settle { successor.count == 1 }
        entered.release()
        await settle { cleanup.count == 1 }
        #expect(!joined && owner.nativeRunning && owner.overlayState == "successor")
        cleanup.release()
        await waiter.value
        #expect(joined && owner.nativeRunning && owner.overlayState == "successor")
        #expect(owner.completionToast == nil)
        successor.release()
        await settle { owner.completionToast == "successor toast" }
        owner.close()
    }

    @Test func externalCachePriorityAndNativeCompletionSuppressionStayExact() async {
        let owner = owner()
        let native = PresentationGate()
        let external = owner.trackExternalDelivery(operation: nil)
        owner.beginNative { report in
            report("native")
            await native.wait()
            return nil
        }
        await settle { native.count == 1 }
        owner.publishExternalDelivery(external, progress: "upload:suppressed")
        owner.completeExternalDelivery(external, message: "suppressed toast")
        #expect(owner.overlayState == "native")
        owner.publishCache(external, progress: "cache:admitted")
        await settle { owner.overlayState == "cache:admitted" }
        native.release()
        await settle { !owner.nativeRunning && owner.overlayState == nil }
        #expect(owner.completionToast == nil)
        owner.publishExternalDelivery(external, progress: "upload:current")
        await settle { owner.overlayState == "upload:current" }
        owner.completeExternalDelivery(external, message: "current toast")
        await settle { owner.completionToast == "current toast" }
        owner.close()
    }

    @Test func reentrantFactCannotClearSuccessorPresentation() async {
        var armed = false
        var capturedOwner: Owner?
        var successor: MonitorDeliveryExternalTicket<String>?
        let owner = Owner(
            isCaching: { _ in
                if armed, let current = capturedOwner {
                    armed = false
                    successor = current.trackExternalDelivery(operation: nil)
                    current.publishCache(successor!, progress: "cache:successor")
                }
                return true
            }, isExternalDelivery: { _ in true }, sleep: { _ in throw CancellationError() })
        capturedOwner = owner
        let old = owner.trackExternalDelivery(operation: nil)
        owner.publishCache(old, progress: "cache:old")
        await settle { owner.overlayState == "cache:old" }
        armed = true
        owner.finishExternalDelivery(old)
        await settle { owner.overlayState == "cache:successor" }
        #expect(successor != nil && owner.completionToast == nil)
        let idle = owner.trackExternalDelivery(
            operation: .init(
                active: {
                    successor = owner.trackExternalDelivery(operation: nil)
                    owner.publishCache(successor!, progress: "upload:successor")
                    return false
                }, cancel: {}))
        owner.publishExternalDelivery(idle, progress: "upload:old")
        await settle { owner.overlayState == "upload:old" }
        owner.noteExternalIdle(idle)
        await settle { owner.overlayState == "upload:successor" }
        #expect(owner.completionToast == nil)
        owner.close()
    }

    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("SIMULATED delivery presentation did not reach its manual gate")
    }
}
