import Foundation
import Observation
import OpenCineAppKit
import Testing

@MainActor private final class CacheObservationGate {
    var continuation: CheckedContinuation<UInt64?, any Error>?
    func read() async throws -> UInt64? {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}
private struct CacheObservationFailure: LocalizedError {
    let errorDescription: String?
}
@MainActor private final class CacheObservationProbe {
    var replaced = false
    var sawClear = false
    var counts = 0
    var clears = 0
}

/// SIMULATED mirror: MonitorSettingsCacheObservationTest. Replies and publication are manually driven.
@MainActor @Suite struct MonitorSettingsCacheObservationTests {
    private func source(count: @escaping @MainActor () async -> UInt64 = { 0 },
        clear: @escaping @MainActor () async throws -> Void = {}, summary: (@MainActor () -> String?)? = nil,
        current: @escaping @MainActor () -> Bool = { true },
        read: (@MainActor () async throws -> UInt64?)? = nil) -> MonitorSettingsCacheSource {
        .init(identity: .init(namespace: "cache", source: nil), revision: 0, isCurrent: current,
            count: count, clear: clear, clearSummary: summary, readObserved: read)
    }
    private func settled(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<1000 { if predicate() { return true }; await Task.yield() }
        return predicate()
    }
    @Test func readFailureKeepsUnknownBytesAndExactReportedMessage() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsCacheModel()
        model.refresh(source(read: { throw CacheObservationFailure(errorDescription: "read denied") }))
        #expect(await settled { model.readFailed })
        #expect(model.bytes == nil && model.failure == "read denied")
        model.refresh(source(count: { 0 }))
        #expect(await settled { model.bytes == 0 })
        #expect(!model.readFailed && model.failure == nil)
        model.retire()
    }
    @Test func absentErrorMessageAndClearReceiptRemainUnknown() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsCacheModel()
        model.refresh(source(read: { throw CacheObservationFailure(errorDescription: nil) }))
        #expect(await settled { model.readFailed })
        #expect(model.bytes == nil && model.failure == nil)
        model.refresh(source()); #expect(await settled { model.bytes == 0 })
        model.requestClear(); model.clear()
        #expect(await settled { !model.clearing && model.bytes == 0 })
        #expect(model.clearSummary == nil)
        model.retire()
    }
    @Test func successfulClearReportsNativeReceiptAndRecounts() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsCacheModel(), probe = CacheObservationProbe()
        let receipt = "Removed 8 MB; kept 2 MB incomplete."
        model.refresh(source(count: { probe.counts += 1; return probe.counts == 1 ? 10 : 2 }, summary: { receipt }))
        #expect(await settled { model.bytes == 10 })
        model.requestClear(); model.clear()
        #expect(await settled { model.bytes == 2 })
        #expect(model.clearSummary == receipt && probe.counts == 2)
        model.retire(); #expect(model.clearSummary == nil)
    }
    @Test func replacementRejectsLateReadFailure() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsCacheModel(), gate = CacheObservationGate()
        model.refresh(source(read: { try await gate.read() }))
        #expect(await settled { gate.continuation != nil })
        model.refresh(source(count: { 7 })); #expect(await settled { model.bytes == 7 })
        gate.continuation?.resume(throwing: CacheObservationFailure(errorDescription: "retired read"))
        gate.continuation = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(model.bytes == 7 && !model.readFailed && model.failure == nil)
        model.retire()
    }
    @Test func summaryReplacementCannotPublishOrRecountSuccessor() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsCacheModel(), probe = CacheObservationProbe()
        let successor = source(count: { probe.counts += 1; return 11 })
        model.refresh(source(count: { 8 }, summary: { model.refresh(successor); return "retired receipt" }))
        #expect(await settled { model.bytes == 8 })
        model.requestClear(); model.clear()
        #expect(await settled { model.bytes == 11 })
        #expect(probe.counts == 1 && model.clearSummary == nil && !model.clearing)
        model.retire()
    }
    @Test func predicateReplacementBeforeClearRefusesOldIO() async {
        guard #available(macOS 14, *) else { return }
        for answer in [false, true] {
            let model = MonitorSettingsCacheModel(), probe = CacheObservationProbe()
            let successor = source(count: { 13 })
            model.refresh(source(count: { 8 }, clear: { probe.clears += 1 }, current: {
                if probe.replaced { probe.replaced = false; model.refresh(successor); return answer }
                return true
            }))
            #expect(await settled { model.bytes == 8 })
            model.requestClear(); probe.replaced = true; model.clear()
            #expect(await settled { model.bytes == 13 })
            #expect(probe.clears == 0 && !model.clearing)
            model.retire()
        }
    }
    @Test func synchronousCountPublicationPreservesSuccessor() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsCacheModel(), probe = CacheObservationProbe()
        let successor = source(count: { probe.counts += 1; return 19 })
        withObservationTracking { _ = model.bytes } onChange: {
            MainActor.assumeIsolated {
                if model.bytes == 8 && !probe.replaced { probe.replaced = true; model.refresh(successor) }
            }
        }
        model.refresh(source(count: { 8 }))
        #expect(await settled { model.bytes == 19 })
        #expect(probe.counts == 1)
        model.retire()
    }
    @available(macOS 14, *) private func observeFinish(_ model: MonitorSettingsCacheModel,
        probe: CacheObservationProbe, successor: MonitorSettingsCacheSource) {
        withObservationTracking { _ = model.clearing } onChange: {
            MainActor.assumeIsolated {
                if model.clearing { probe.sawClear = true; observeFinish(model, probe: probe, successor: successor) }
                else if probe.sawClear && !probe.replaced { probe.replaced = true; model.refresh(successor) }
            }
        }
    }
    @Test func synchronousClearFinishPreservesSuccessorTask() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsCacheModel(), probe = CacheObservationProbe()
        let successor = source(count: { probe.counts += 1; return 23 })
        observeFinish(model, probe: probe, successor: successor)
        model.refresh(source(count: { 8 })); #expect(await settled { model.bytes == 8 })
        model.requestClear(); model.clear()
        #expect(await settled { model.bytes == 23 })
        #expect(probe.counts == 1 && model.clearSummary == nil)
        model.retire()
    }
}
