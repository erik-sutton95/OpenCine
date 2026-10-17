import Foundation
import OpenCineCore
import Testing

@testable import OpenCineNikon

@MainActor
@Suite("Nikon integration-owned monitor controls")
struct NikonMonitorRuntimeTests {
    @Test("Record keeps its explicit target and precedes queued setting writes")
    func recordBeforeSettings() async {
        let link = Link()
        let runtime = NikonMonitorRuntime(link: link, facts: NikonCameraSessionTests.movieFacts())
        let setting = runtime.session.request(.set(.iso(.manual(1600))))
        let record = runtime.session.request(.startRecording)
        #expect(await runtime.serviceControlSafePoint(allowWrites: false))
        #expect(link.commands == ["record-start"])
        #expect(runtime.session.receipt(of: record.operation)?.stage == .awaitingObservation)
        var facts = NikonCameraSessionTests.movieFacts()
        facts.recording = true
        runtime.updateFacts(facts)
        #expect(runtime.session.receipt(of: record.operation)?.stage == .confirmed)
        while runtime.hasQueuedCommands { await runtime.serviceControlSafePoint() }
        #expect(runtime.session.receipt(of: setting.operation)?.stage == .confirmed)
        #expect(link.commands.dropFirst().allSatisfy { $0.hasPrefix("write ") })
    }

    @Test("A movie exposure queued before a selector change never reaches the body")
    func queuedExposureRetiresAtTheSafePoint() async {
        let link = Link()
        var facts = NikonCameraSessionTests.movieFacts()
        facts.reported = facts.reported
            .applying(
                property: .movieShutterMode,
                data: Data([PTPCameraPropertyDecoders.shutterModeCode(.speed)])
            )
            .applying(property: .movieShutterSpeed, data: Data(ByteCoding.uint32LE(1 << 16 | 50)))
        facts.shutterLabels = ["1/50", "1/100"]
        let runtime = NikonMonitorRuntime(link: link, facts: facts)
        let queued = runtime.session.request(.set(.shutter(.duration(Rational(1, 100)))))
        #expect(queued.stage == .admitted)
        facts.reported = facts.reported.applying(property: .liveViewSelector, data: Data([0]))
        runtime.updateFacts(facts)
        #expect(await runtime.serviceControlSafePoint())
        #expect(link.commands.isEmpty)
        #expect(runtime.session.receipt(of: queued.operation)?.stage == .failed(.notSent))
        #expect(!runtime.hasQueuedCommands)
    }

    @Test("The latest ISO target coalesces without losing dependent writes")
    func coalescesLatestTarget() async {
        let link = Link()
        let runtime = NikonMonitorRuntime(link: link, facts: NikonCameraSessionTests.movieFacts())
        let old = runtime.session.request(.set(.iso(.manual(1600))))
        let latest = runtime.session.request(.set(.iso(.manual(3200))))
        #expect(runtime.session.receipt(of: old.operation)?.stage == .failed(.superseded))
        while runtime.hasQueuedCommands { await runtime.serviceControlSafePoint() }
        #expect(runtime.session.receipt(of: latest.operation)?.stage == .confirmed)
        #expect(runtime.session.refresh().value(of: .iso).value == .iso(.manual(3200)))
    }

    @Test("Recovery holds one common session, advances epoch and refuses old editors")
    func recoveryRetainsIdentity() async {
        let runtime = NikonMonitorRuntime(link: Link(), facts: NikonCameraSessionTests.movieFacts())
        let before = runtime.session.refresh()
        let old = CameraCommand(
            .set(.iso(.manual(1600))), preconditions: CommandPreconditions(before))
        runtime.recovering()
        runtime.updateFacts(NikonControlFacts())
        let recovering = runtime.session.refresh()
        #expect(recovering.session == before.session)
        #expect(recovering.value(of: .iso) == before.value(of: .iso))
        if case .recovering = recovering.connection {
        } else {
            Issue.record("expected held recovery")
        }
        runtime.replaceLink(Link())
        let after = runtime.session.refresh()
        #expect(after.session == before.session)
        #expect(after.epoch != before.epoch)
        #expect(runtime.session.submit(old).stage == .rejected(.staleEpoch))
    }

    /// A5-04: the header timecode is the runtime's own observation. An app fact refresh keeps
    /// it; recovery makes it unknown rather than freezing the last counter.
    @Test("Header timecode survives app fact refreshes and clears on recovery")
    func headerTimecodeOwnership() async {
        let runtime = NikonMonitorRuntime(link: Link(), facts: NikonCameraSessionTests.movieFacts())
        runtime.observeHeader(timecode: Timecode(on: true, hour: 0, minute: 0, second: 9, frame: 4))
        #expect(runtime.session.refresh().timecode.value?.frames == 4)
        runtime.updateFacts(NikonCameraSessionTests.movieFacts())
        #expect(runtime.session.refresh().timecode.value?.seconds == 9)
        runtime.observeHeader(timecode: Timecode(on: false, hour: 0, minute: 0, second: 9, frame: 5))
        #expect(runtime.session.refresh().timecode == .unknown)
        runtime.observeHeader(timecode: Timecode(on: true, hour: 0, minute: 0, second: 10, frame: 0))
        runtime.recovering()
        #expect(runtime.session.refresh().timecode == .unknown)
    }

    @Test("Authority loss drops admitted commands before they reach the body")
    func authorityLossRetiresQueue() async {
        let link = Link()
        let runtime = NikonMonitorRuntime(link: link, facts: NikonCameraSessionTests.movieFacts())
        let pending = runtime.session.request(.set(.iso(.manual(1600))))
        var facts = NikonCameraSessionTests.movieFacts()
        facts.holdsControl = false
        runtime.updateFacts(facts)
        #expect(!runtime.hasQueuedCommands)
        #expect(runtime.session.receipt(of: pending.operation)?.stage == .failed(.notSent))
        #expect(!(await runtime.serviceControlSafePoint()))
        #expect(link.commands.isEmpty)
    }

    @Test("An old transport finishing after replacement cannot publish its readback")
    func lateReadbackIsRetired() async {
        let link = Link()
        link.holdWrite = true
        let runtime = NikonMonitorRuntime(link: link, facts: NikonCameraSessionTests.movieFacts())
        var projected = 0
        runtime.onReadback = { _, _ in projected += 1 }
        let pending = runtime.session.request(.set(.iso(.manual(1600))))
        let service = Task { await runtime.serviceControlSafePoint() }
        await link.waitUntilHeld()
        runtime.recovering()
        runtime.replaceLink(Link())
        link.releaseWrite()
        _ = await service.value
        #expect(projected == 0)
        #expect(runtime.session.receipt(of: pending.operation)?.stage == .outcomeUnknown)
        #expect(runtime.session.refresh().value(of: .iso).value == .iso(.manual(800)))
    }

    @Test("Borrowed teardown retires controls without closing or stopping the member")
    func borrowedReturnDoesNotClose() async {
        let link = Link()
        let runtime = NikonMonitorRuntime(link: link, ownsLink: false)
        runtime.session.close(.requested)
        #expect(runtime.teardown == nil)
        #expect(link.commands.isEmpty)
        #expect(link.closes == 0)
    }

    @Test("Retiring during bootstrap drains its native write without cancelling a kept socket")
    func retirementDrainsBootstrap() async {
        let link = Link()
        link.holdWrite = true
        let runtime = NikonMonitorRuntime(link: link, ownsLink: false)
        var delivered = 0
        runtime.startPreview(
            bootstrap: {
                try? await link.writeCameraProperty(.init(property: .dateTime, data: Data()))
            },
            demand: { .init(mode: .picture, size: 2, compression: 1) },
            consume: { _, _ in
                delivered += 1
                return true
            }, safePoint: { _, _ in },
            applied: { _ in }, resetCadence: {}, health: { _ in }, event: { _ in })
        await link.waitUntilHeld()
        let retirement = runtime.retirePumps()
        link.releaseWrite()
        await retirement?.value
        #expect(!link.wireWasCancelled)
        #expect(delivered == 0)
        #expect(link.closes == 0)
        #expect(!link.commands.contains("live-stop"))
    }

    @Test("A borrowed pushed-event read drains without cancelling or publishing into retirement")
    func retirementDrainsEventReader() async {
        let link = Link()
        link.holdEvent = true
        let runtime = NikonMonitorRuntime(link: link, ownsLink: false)
        var ended = 0
        runtime.startEventDrain(
            receive: { _ in Issue.record("late event") }, unexpectedEnd: { ended += 1 })
        await link.waitUntilHeld()
        let retirement = runtime.retirePumps()
        link.releaseWrite()
        await retirement?.value
        #expect(!link.wireWasCancelled)
        #expect(ended == 0)
        #expect(link.closes == 0)
    }

    @Test("Repeated event-drain starts serialize kept reads and retirement retains both owners")
    func repeatedEventStartsDrainPriorOwner() async {
        let link = Link()
        link.holdEvent = true
        let runtime = NikonMonitorRuntime(link: link, ownsLink: false)
        runtime.startEventDrain(receive: { _ in Issue.record("late event") }, unexpectedEnd: {})
        await link.waitUntilHeld()
        runtime.startEventDrain(receive: { _ in Issue.record("late event") }, unexpectedEnd: {})
        await Task.yield()
        #expect(link.eventReads == 1)
        link.releaseWrite()
        await link.waitUntilHeld()
        #expect(link.eventReads == 2)
        let retirement = runtime.retirePumps()
        link.releaseWrite()
        await retirement?.value
        #expect(link.activeReaders == 0)
        #expect(link.maxReaders == 1)
        #expect(!link.wireWasCancelled)
        #expect(link.closes == 0)
    }

    @Test("Repeated keepalive starts drain the kept ping before its successor or borrowed return")
    func repeatedKeepAliveStartsDrainPriorOwner() async {
        let link = Link()
        link.holdPing = true
        let runtime = NikonMonitorRuntime(
            link: link, ownsLink: false, backgroundSleep: { _ in await Task.yield() })
        runtime.startKeepAlive(isBusy: { false }, failures: { _ in }, recover: {})
        await link.waitUntilHeld()
        runtime.startKeepAlive(isBusy: { false }, failures: { _ in }, recover: {})
        await Task.yield()
        #expect(link.pings == 1)
        link.releaseWrite()
        await link.waitUntilHeld()
        #expect(link.pings == 2)
        let retirement = runtime.retirePumps()
        link.releaseWrite()
        await retirement?.value
        #expect(link.activeReaders == 0)
        #expect(link.maxReaders == 1)
        #expect(!link.wireWasCancelled)
        #expect(link.closes == 0)
    }

    @Test("Owned close releases the native session once without stopping recording")
    func ownedCloseIsOnce() async {
        let link = Link()
        let runtime = NikonMonitorRuntime(link: link)
        runtime.session.close(.requested)
        runtime.session.close(.requested)
        await runtime.teardown?.value
        #expect(link.closes == 1)
        #expect(link.commands == ["live-stop"])
    }
}

@MainActor
private final class Link: NikonMonitorLink {
    let serialNumber = "3000123"
    private(set) var commands: [String] = []
    private(set) var closes = 0
    var holdWrite = false
    var holdEvent = false
    var holdPing = false
    var eventReads = 0
    var pings = 0
    var activeReaders = 0
    var maxReaders = 0
    var wireWasCancelled = false
    private var properties: [PTPPropertyCode: Data] = [:]
    private var held: [CheckedContinuation<Void, Never>] = []
    private var heldWaiter: CheckedContinuation<Void, Never>?

    func supportsProperty(_ property: PTPPropertyCode) -> Bool { true }
    func configureLiveView(size: UInt8, compression: UInt8) async {}
    func startLiveView() async throws {}
    func stopLiveView() async { commands.append("live-stop") }
    func liveViewFrame(deadline: Duration?) async throws -> PTPLiveViewFrame {
        throw NativeCameraSessionError.connectionClosed
    }
    func readLastCommandRoundTripMilliseconds() -> Double? { nil }
    func sendKeepAlive() async throws {
        pings += 1
        activeReaders += 1
        maxReaders = max(maxReaders, activeReaders)
        defer { activeReaders -= 1 }
        if holdPing { await hold() }
        wireWasCancelled = wireWasCancelled || Task.isCancelled
    }
    func nextEvent() async throws -> PTPEvent {
        eventReads += 1
        activeReaders += 1
        maxReaders = max(maxReaders, activeReaders)
        defer { activeReaders -= 1 }
        if holdEvent { await hold() }
        wireWasCancelled = wireWasCancelled || Task.isCancelled
        throw NativeCameraSessionError.connectionClosed
    }
    func pollStillReleaseReadiness() async throws -> StillReleaseReadiness { .complete }
    func shutdown() async { closes += 1 }
    func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws {
        commands.append("write \(write.property)")
        if holdWrite { await hold() }
        wireWasCancelled = wireWasCancelled || Task.isCancelled
        properties[write.property] = write.data
    }
    func readCameraProperty(_ property: PTPPropertyCode) async throws -> Data {
        guard let value = properties[property] else {
            throw NativeCameraSessionError.connectionClosed
        }
        return value
    }
    func startRecording() async throws { commands.append("record-start") }
    func stopRecording() async throws { commands.append("record-stop") }
    private func hold() async {
        await withCheckedContinuation { continuation in
            held.append(continuation)
            heldWaiter?.resume()
            heldWaiter = nil
        }
    }
    func waitUntilHeld() async {
        if !held.isEmpty { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }
    func releaseWrite() {
        if !held.isEmpty { held.removeFirst().resume() }
    }
}
