import Foundation
import OpenCineAppKit
import Testing

@MainActor private final class SettingsCacheIO {
    struct Count { let continuation: CheckedContinuation<UInt64, Never> }
    struct Clear { let continuation: CheckedContinuation<Void, any Error> }
    var counts: [Count] = []
    var clears: [Clear] = []
    var current = true
    var cleared: [String] = []
    func source(_ identity: MonitorSettingsCacheIdentity, revision: UInt64 = 0) -> MonitorSettingsCacheSource {
        .init(identity: identity, revision: revision, isCurrent: { self.current },
            count: { await withCheckedContinuation { self.counts.append(.init(continuation: $0)) } },
            clear: { try await withCheckedThrowingContinuation { self.clears.append(.init(continuation: $0)) } })
    }
}

/// Kotlin mirror: MonitorSettingsCacheModelTest. Held IO deliberately replies after retirement.
@MainActor @Suite struct MonitorSettingsCacheModelTests {
    private func settled(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<1000 { if predicate() { return true }; await Task.yield() }
        return predicate()
    }
    @Test func currentEmptyCacheIsKnownZero() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsCacheModel(), io = SettingsCacheIO()
        model.refresh(io.source(.init(namespace: "original-cache", source: nil)))
        #expect(await settled { io.counts.count == 1 })
        #expect(model.bytes == nil)
        io.counts[0].continuation.resume(returning: 0)
        #expect(await settled { model.bytes == 0 })
        model.retire()
    }
    @Test func replacementRejectsOldCount() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsCacheModel(), first = SettingsCacheIO(), next = SettingsCacheIO()
        model.refresh(first.source(.init(namespace: "A", source: UUID())))
        #expect(await settled { first.counts.count == 1 })
        model.refresh(next.source(.init(namespace: "B", source: UUID())))
        #expect(await settled { next.counts.count == 1 })
        first.counts[0].continuation.resume(returning: 99)
        for _ in 0..<20 { await Task.yield() }
        #expect(model.bytes == nil)
        next.counts[0].continuation.resume(returning: 7)
        #expect(await settled { model.bytes == 7 })
        model.retire()
    }
    @Test func revisionRefreshRejectsOldCountInSameNamespace() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsCacheModel(), io = SettingsCacheIO()
        let identity = MonitorSettingsCacheIdentity(namespace: "A", source: UUID())
        model.refresh(io.source(identity))
        #expect(await settled { io.counts.count == 1 })
        model.refresh(io.source(identity, revision: 1))
        #expect(await settled { io.counts.count == 2 })
        io.counts[1].continuation.resume(returning: 8)
        #expect(await settled { model.bytes == 8 })
        io.counts[0].continuation.resume(returning: 99)
        for _ in 0..<20 { await Task.yield() }
        #expect(model.bytes == 8)
        model.retire()
    }
    @Test func lostAuthorityAndReplacementRetireCapturedConfirmation() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsCacheModel(), io = SettingsCacheIO()
        model.refresh(io.source(.init(namespace: "A", source: UUID())))
        #expect(await settled { io.counts.count == 1 })
        io.counts[0].continuation.resume(returning: 9)
        model.requestClear(); #expect(model.confirmationPresented)
        io.current = false; model.clear()
        #expect(!model.clearing && !model.confirmationPresented && io.clears.isEmpty)
        io.current = true; model.requestClear()
        model.refresh(io.source(.init(namespace: "A", source: UUID())))
        #expect(await settled { io.counts.count == 2 })
        model.clear(); #expect(io.clears.isEmpty && !model.confirmationPresented)
        io.counts[1].continuation.resume(returning: 9); model.retire()
    }
    @Test func disappearedThenReenteredCacheRejectsLateClearFailure() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsCacheModel(), io = SettingsCacheIO()
        let identity = MonitorSettingsCacheIdentity(namespace: "A", source: UUID())
        model.refresh(io.source(identity)); #expect(await settled { io.counts.count == 1 })
        io.counts[0].continuation.resume(returning: 9)
        model.requestClear(); model.clear(); #expect(await settled { io.clears.count == 1 })
        model.retire(); model.refresh(io.source(identity)); #expect(await settled { io.counts.count == 2 })
        io.counts[1].continuation.resume(returning: 3)
        io.clears[0].continuation.resume(throwing: CocoaError(.fileWriteUnknown))
        #expect(await settled { model.bytes == 3 })
        #expect(!model.clearFailed && !model.clearing)
        model.retire()
    }
    @Test func cancellingConfirmationSendsNoIOAndClearRunsOnce() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsCacheModel(), io = SettingsCacheIO()
        model.refresh(io.source(.init(namespace: "A", source: nil))); #expect(await settled { io.counts.count == 1 })
        io.counts[0].continuation.resume(returning: 8)
        model.requestClear(); model.cancelConfirmation(); model.clear()
        #expect(io.clears.isEmpty)
        model.requestClear(); model.clear(); model.requestClear(); model.clear()
        #expect(await settled { io.clears.count == 1 })
        io.clears[0].continuation.resume(throwing: CocoaError(.fileWriteUnknown))
        #expect(await settled { model.clearFailed && !model.clearing })
        if await settled({ io.counts.count == 2 }) {
            io.counts[1].continuation.resume(returning: 8)
        }
        model.retire(); #expect(!model.clearFailed)
    }
    @Test func failedClearRecountsRemainingBytesAndRetainsTheFailure() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsCacheModel(), io = SettingsCacheIO()
        model.refresh(io.source(.init(namespace: "original-cache", source: UUID())))
        #expect(await settled { io.counts.count == 1 })
        io.counts[0].continuation.resume(returning: 800)
        #expect(await settled { model.bytes == 800 })
        model.requestClear(); model.clear()
        #expect(await settled { io.clears.count == 1 })
        io.clears[0].continuation.resume(throwing: NSError(domain: "SettingsCacheTest", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "remaining bucket failed"]))
        let recounted = await settled { io.counts.count == 2 }
        #expect(recounted)
        #expect(model.clearFailed && !model.clearing)
        let failure = model.failure
        #expect(failure != nil)
        if recounted {
            #expect(model.bytes == nil)
            io.counts[1].continuation.resume(returning: 300)
            #expect(await settled { model.bytes == 300 })
            #expect(model.clearFailed && model.failure == failure)
        }
        model.retire()
    }

    @Test func successfulClearRecountsTheCapturedNamespaceWithoutAContentReport() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsCacheModel(), io = SettingsCacheIO()
        model.refresh(io.source(.init(namespace: "original-cache", source: UUID())))
        #expect(await settled { io.counts.count == 1 })
        io.counts[0].continuation.resume(returning: 800)
        #expect(await settled { model.bytes == 800 })
        model.requestClear(); model.clear()
        #expect(await settled { io.clears.count == 1 })
        io.clears[0].continuation.resume()
        #expect(await settled { io.counts.count == 2 })
        #expect(!model.clearing && model.bytes == nil)
        io.counts[1].continuation.resume(returning: 0)
        #expect(await settled { model.bytes == 0 })
        model.retire()
    }

    /// A2-58: delivery exports count toward Settings storage and clear with the cache.
    @Test func anAddedStoreIsCountedAndClearedWithTheCache() async {
        guard #available(macOS 14, *) else { return }
        let io = SettingsCacheIO()
        let base = MonitorSettingsCacheSource(
            identity: .init(namespace: "A", source: nil), revision: 0, isCurrent: { true },
            count: { 100 }, clear: { io.cleared.append("cache") })
        let model = MonitorSettingsCacheModel()
        model.refresh(base.adding(count: { 23 }, clear: { io.cleared.append("exports") }))
        #expect(await settled { model.bytes == 123 })
        model.requestClear()
        model.clear()
        #expect(await settled { io.cleared == ["cache", "exports"] })
        model.retire()
    }
}
