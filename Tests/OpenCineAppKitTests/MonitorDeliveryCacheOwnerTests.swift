import Foundation
import OpenCineAppKit
import Testing

@MainActor private final class CacheOwnerGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var count: Int { waiting.count }
    func wait() async { await withCheckedContinuation { waiting.append($0) } }
    func release() { waiting.removeFirst().resume() }
}
@MainActor private final class CacheOwnerFacts {
    var current = true
    var cached: Set<Int> = []
    var calls: [Int] = []
    var progress: [MonitorDeliveryBatchProgress] = []
    var fraction: Double?
}

/// SIMULATED cache-only admission in the existing delivery run; no export/upload is invoked.
@MainActor @Suite struct MonitorDeliveryCacheOwnerTests {
    typealias Model = MonitorDeliveryModel<Int, Int, Int>
    @Test func sequentialOriginalsKeepOrderAndPartialReceipts() async {
        let facts = CacheOwnerFacts()
        facts.cached = [2]
        let result = await Model.cacheOriginals(
            records: [1, 2, 3], destination: .nativeShare,
            admission: .init { facts.current },
            originals: .init(
                available: { facts.cached.contains($0) },
                acquire: { value in
                    facts.calls.append(value)
                    if value == 1 { facts.cached.insert(value) }
                },
                progress: { _ in nil }), filename: { "\($0).mov" },
            sleep: { _ in throw CancellationError() }, progress: { facts.progress.append($0) })
        #expect(result?.ready == [1, 2] && result?.uncached == 1 && facts.calls == [1, 3])
        #expect(facts.progress.map(\.clipIndex) == [1, 2])
        #expect(facts.progress.allSatisfy { $0.isCaching && $0.totalClips == 2 })
    }
    @Test func retiredSourceBeforeFirstIORejectsAllWork() async {
        let facts = CacheOwnerFacts()
        let result = await Model.cacheOriginals(
            records: [1], destination: .nativeShare,
            admission: .init { facts.current },
            originals: .init(
                available: { _ in
                    facts.current = false
                    return false
                },
                acquire: { facts.calls.append($0) }, progress: { _ in nil }), filename: { "\($0)" },
            progress: { facts.progress.append($0) })
        #expect(result == nil && facts.calls.isEmpty && facts.progress.isEmpty)
    }
    @Test func sourceReplacementDuringProgressRefusesUnsentAcquisition() async {
        let facts = CacheOwnerFacts()
        let result = await Model.cacheOriginals(
            records: [1, 2], destination: .nativeShare,
            admission: .init { facts.current },
            originals: .init(
                available: { _ in false },
                acquire: { facts.calls.append($0) }, progress: { _ in nil }), filename: { "\($0)" },
            progress: {
                facts.progress.append($0)
                facts.current = false
            })
        #expect(result == nil && facts.calls.isEmpty && facts.progress.count == 1)
    }
    @Test func enteredCompletionFinishesWithoutASuccessorReceipt() async {
        let facts = CacheOwnerFacts()
        let entered = CacheOwnerGate()
        var result: MonitorDeliveryCachedOriginals<Int>?
        let work = Task {
            result = await Model.cacheOriginals(
                records: [1, 2], destination: .nativeShare,
                admission: .init { facts.current },
                originals: .init(
                    available: { facts.cached.contains($0) },
                    acquire: { value in
                        facts.calls.append(value)
                        await entered.wait()
                        facts.cached.insert(value)
                    },
                    progress: { _ in nil }), filename: { "\($0)" },
                sleep: { _ in throw CancellationError() }, progress: { facts.progress.append($0) })
        }
        await settle { entered.count == 1 }
        facts.current = false
        entered.release()
        await work.value
        #expect(facts.cached == [1] && facts.calls == [1] && result == nil)
        #expect(facts.progress.count == 1)
    }
    @Test func lateManualMirrorCannotPublishAfterEnteredCompletion() async {
        let facts = CacheOwnerFacts()
        let entered = CacheOwnerGate()
        let clock = CacheOwnerGate()
        let work = Task {
            await Model.cacheOriginals(
                records: [1], destination: .nativeShare,
                admission: .init { facts.current },
                originals: .init(
                    available: { facts.cached.contains($0) },
                    acquire: { value in
                        await entered.wait()
                        facts.cached.insert(value)
                    },
                    progress: { _ in facts.fraction }), filename: { "\($0)" },
                sleep: { duration in
                    #expect(duration == .milliseconds(200))
                    await clock.wait()
                },
                progress: { facts.progress.append($0) })
        }
        await settle { entered.count == 1 && clock.count == 1 }
        clock.release()
        await settle { clock.count == 1 }
        #expect(facts.progress.count == 1)
        facts.fraction = 0.6
        clock.release()
        await settle { facts.progress.count == 2 && clock.count == 1 }
        #expect(facts.progress.last?.clipFraction == 0.6)
        entered.release()
        let result = await work.value
        #expect(result?.ready == [1])
        facts.fraction = 0.9
        clock.release()
        for _ in 0..<10 { await Task.yield() }
        #expect(facts.progress.count == 2)
    }
    @Test func finalReceiptCannotBorrowARefreshedSource() async {
        let facts = CacheOwnerFacts()
        var observations = 0
        let result = await Model.cacheOriginals(
            records: [1], destination: .nativeShare,
            admission: .init { facts.current },
            originals: .init(
                available: { _ in
                    observations += 1
                    if observations == 2 { facts.current = false }
                    return true
                }, acquire: { facts.calls.append($0) }, progress: { _ in nil }),
            filename: { "\($0)" },
            progress: { facts.progress.append($0) })
        #expect(result == nil && observations == 2 && facts.calls.isEmpty && facts.progress.isEmpty)
    }
    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("SIMULATED delivery cache did not reach its manual gate")
    }
}
