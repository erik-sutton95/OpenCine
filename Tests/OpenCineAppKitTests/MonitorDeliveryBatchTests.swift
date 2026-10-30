import Foundation
import OpenCineAppKit
import Testing

@MainActor private final class DeliveryBatchGate<T: Sendable> {
    private var waiting: [CheckedContinuation<T, Never>] = []
    var count: Int { waiting.count }
    func value() async -> T { await withCheckedContinuation { waiting.append($0) } }
    func release(_ value: T) { waiting.removeFirst().resume(returning: value) }
}
@MainActor private final class DeliveryBatchFacts {
    var cached: Set<Int> = []
    var calls: [String] = []
    var progress: [MonitorDeliveryBatchProgress] = []
    var late: [(@MainActor @Sendable (Double) -> Void)] = []
    var fraction: Double?
}
@MainActor @Suite struct MonitorDeliveryBatchTests {
    typealias Outcome = MonitorDeliveryBatchOutcome<String>
    typealias Model = MonitorDeliveryModel<MonitorDeliveryBatchProgress, Outcome, String>
    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 { if predicate() { return }; await Task.yield() }
        Issue.record("SIMULATED delivery did not reach its manual gate")
    }
    private func originals(_ facts: DeliveryBatchFacts) -> MonitorDeliveryOriginalService<Int> {
        .init(available: { facts.cached.contains($0) }, acquire: { facts.calls.append("cache \($0)"); facts.cached.insert($0) },
            progress: { _ in facts.fraction })
    }
    private func exporter(_ facts: DeliveryBatchFacts) -> MonitorDeliveryExportService<Int, String> {
        .init { record, progress in
            facts.calls.append("prepare \(record)"); facts.late.append(progress); progress(0.8); return "\(record)"
        }
    }
    private func completion(_ outcome: Outcome) -> MonitorDeliveryCompletion<Outcome, String> {
        if case .share(_, _, let lease) = outcome { return .init(outcome, share: lease) }
        return .init(outcome)
    }
    @Test func uploadPresentationUsesHostContentAndNeutralDestination() {
        #expect(MonitorDeliveryDestination.remoteUpload.title(remoteDisplayName: "SIMULATED service") == "SIMULATED service")
        #expect(MonitorDeliveryDestination.remoteUpload.subtitle(remoteDisplayName: "SIMULATED service") == "Upload to your SIMULATED service project")
        #expect(MonitorDeliveryDestination.remoteUpload.title(remoteDisplayName: nil) == "Upload")
        let value = MonitorDeliveryBatchProgress(destination: .remoteUpload, totalClips: 1,
            clipIndex: 1, clipFraction: 0.6, uploadCaption: "SIMULATED upload")
        #expect(value.statusLine() == "SIMULATED upload 60%")
        #expect(value.statusLine(uploadCaption: "SIMULATED second service") == "SIMULATED second service 60%")
    }
    @Test func originalReceiptsAndPreparationKeepSelectionOrder() async {
        let facts = DeliveryBatchFacts(); facts.cached = [2]
        let outcome = await Model.runBatch(records: [1, 2, 3], destination: .nativeShare, action: .systemShare,
            admission: .init { true }, originals: originals(facts), exporter: exporter(facts),
            share: { .init(urls: $0) }, photos: nil, internet: Optional<MonitorDeliveryInternetService<Int>>.none,
            filename: { "\($0)" }, progress: { facts.progress.append($0) })
        guard case .share(let urls, _, _) = outcome else { Issue.record("Missing ordered original result"); return }
        #expect(urls == ["1", "2", "3"])
        #expect(facts.calls == ["cache 1", "cache 3", "prepare 1", "prepare 2", "prepare 3"])
        let count = facts.progress.count
        for late in facts.late { late(0.1) }
        #expect(facts.progress.count == count)
    }
    @Test func remotePartialFailureKeepsWeightsAndExactCounts() async {
        let facts = DeliveryBatchFacts()
        let outcome: Outcome = await Model.runBatch(records: [1, 2, 3, 4], destination: .remoteUpload, action: .systemShare,
            admission: .init { true }, originals: .init(available: { facts.cached.contains($0) },
                acquire: { if $0 != 2 { facts.cached.insert($0) } }, progress: { _ in nil }),
            exporter: .init { record, progress in
                facts.calls.append("prepare \(record)")
                if record == 3 { return nil }
                if record == 4 { throw NSError(domain: "SIMULATED", code: 1, userInfo: [NSLocalizedDescriptionKey: "export failed"]) }
                progress(0.8); return "\(record)"
            }, share: nil, photos: nil, upload: .init { artifact, progress in
                facts.calls.append("upload \(artifact)"); progress(0.5)
            }, internet: Optional<MonitorDeliveryInternetService<Int>>.none,
            filename: { "\($0)" }, progress: { facts.progress.append($0) })
        guard case .failed(let message) = outcome else { Issue.record("Missing partial failure"); return }
        #expect(message == "1 uploaded, 1 skipped, 1 not cached, 1 failed")
        #expect(facts.calls == ["prepare 1", "upload 1", "prepare 3", "prepare 4"])
        #expect(facts.progress.contains { $0.stage == .exporting && abs($0.clipFraction - 0.36) < 0.000001 })
        #expect(facts.progress.contains { $0.stage == .uploading && abs($0.clipFraction - 0.725) < 0.000001 })
    }
    /// A2-56: the one policy continues past a failing item; with nothing prepared the outcome
    /// reports the first failure.
    @Test func nativeFailureContinuesToTheNextPreparation() async {
        let facts = DeliveryBatchFacts(); facts.cached = [1, 2]
        let outcome = await Model.runBatch(records: [1, 2], destination: .nativeShare, action: .systemShare,
            admission: .init { true }, originals: originals(facts), exporter: .init { record, _ in
                facts.calls.append("prepare \(record)")
                throw NSError(domain: "SIMULATED", code: 1, userInfo: [NSLocalizedDescriptionKey: "native failed"])
            }, share: { values in facts.calls.append("share"); return MonitorDeliveryShareFiles<String>(urls: values) },
            photos: nil, internet: Optional<MonitorDeliveryInternetService<Int>>.none,
            filename: { "\($0)" }, progress: { facts.progress.append($0) })
        guard case .failed(let message) = outcome else { Issue.record("Missing native failure"); return }
        #expect(message == "native failed" && facts.calls == ["prepare 1", "prepare 2"])
    }
    /// Owner report 2026-10-29: a camera that stops answering mid-cache is named as such; a
    /// clip that simply could not be cached keeps the connection advice.
    @Test func cacheFailureSaysWhenTheCameraStoppedResponding() async {
        for stopped in [true, false] {
            let facts = DeliveryBatchFacts()
            let outcome = await Model.runBatch(records: [1], destination: .nativeShare, action: .systemShare,
                admission: .init { true }, originals: .init(available: { _ in false },
                    acquire: { facts.calls.append("cache \($0)") }, progress: { _ in nil },
                    cameraStoppedResponding: { _ in stopped }), exporter: exporter(facts),
                share: { .init(urls: $0) }, photos: nil, internet: Optional<MonitorDeliveryInternetService<Int>>.none,
                filename: { "\($0)" }, progress: { _ in })
            guard case .failed(let message) = outcome else { Issue.record("Missing cache failure"); return }
            #expect(message == (stopped
                ? "The camera stopped responding while caching 1 clip(s). Reconnect and try again."
                : "Couldn't cache 1 clip(s) from the camera. Check the connection and try again."))
            #expect(facts.calls == ["cache 1"])
        }
    }
    @Test func manualCacheProgressIgnoresUnknownAndLateTicks() async {
        let facts = DeliveryBatchFacts()
        let clock = DeliveryBatchGate<Void>(), acquire = DeliveryBatchGate<Void>()
        let model = Model()
        model.beginAdmitted { progress, admission in
            let outcome = await Model.runBatch(records: [1], destination: .nativeShare, action: .systemShare,
                admission: admission, originals: .init(available: { facts.cached.contains($0) }, acquire: { record in
                    await acquire.value(); facts.cached.insert(record)
                }, progress: { _ in facts.fraction }), exporter: exporter(facts),
                share: { .init(urls: $0) }, photos: nil, internet: Optional<MonitorDeliveryInternetService<Int>>.none,
                filename: { "\($0)" }, sleep: { duration in
                    #expect(duration == .milliseconds(200)); await clock.value()
                }, progress: { facts.progress.append($0); progress($0) })
            return completion(outcome)
        }
        await settle { acquire.count == 1 && clock.count == 1 }
        let initial = facts.progress.count
        clock.release(())
        await settle { clock.count == 1 }
        #expect(facts.progress.count == initial)
        facts.fraction = 0.25; clock.release(())
        await settle { model.state.progress?.clipFraction == 0.25 && clock.count == 1 }
        acquire.release(())
        await settle { !model.state.running }
        let finished = facts.progress.count
        clock.release(())
        for _ in 0..<20 { await Task.yield() }
        #expect(facts.progress.count == finished && model.state.progress == nil)
        model.close()
    }
    @Test func retiredAcquisitionCannotPrepareOrCancelSuccessor() async {
        let facts = DeliveryBatchFacts(), acquire = DeliveryBatchGate<Void>(), clock = DeliveryBatchGate<Void>()
        let successor = DeliveryBatchGate<MonitorDeliveryCompletion<Outcome, String>>()
        let model = Model()
        model.beginAdmitted { progress, admission in
            let outcome = await Model.runBatch(records: [1, 2], destination: .nativeShare, action: .systemShare,
                admission: admission, originals: .init(available: { facts.cached.contains($0) }, acquire: { record in
                    facts.calls.append("cache \(record)"); await acquire.value(); facts.cached.insert(record)
                }, progress: { _ in nil }), exporter: exporter(facts), share: { .init(urls: $0) },
                photos: nil, internet: Optional<MonitorDeliveryInternetService<Int>>.none,
                filename: { "\($0)" }, sleep: { _ in await clock.value() }, progress: progress)
            return completion(outcome)
        }
        await settle { acquire.count == 1 }
        model.begin { progress in progress(.init(destination: .nativeShare, totalClips: 1, clipIndex: 1, clipFraction: 0.7)); return await successor.value() }
        await settle { successor.count == 1 }
        acquire.release(())
        for _ in 0..<20 { await Task.yield() }
        #expect(facts.calls == ["cache 1"] && model.state.running && model.state.progress?.clipFraction == 0.7)
        if clock.count > 0 { clock.release(()) }
        successor.release(.init(.savedToPhotos(count: 1)))
        await settle { !model.state.running }; model.close()
    }
    @Test func sourcePredicateReplacementRejectsFalseAndTrueReplies() async {
        for reply in [false, true] {
            let facts = DeliveryBatchFacts(); facts.cached = [1]
            let gate = DeliveryBatchGate<MonitorDeliveryCompletion<Outcome, String>>()
            let model = Model(); var replace = true
            model.beginAdmitted { progress, admission in
                let source = MonitorDeliveryAdmission {
                    guard admission.isCurrent() else { return false }
                    if replace {
                        replace = false
                        model.begin { progress in
                            progress(.init(destination: .nativeShare, totalClips: 1, clipIndex: 1, clipFraction: 0.6))
                            return await gate.value()
                        }
                        return reply && admission.isCurrent()
                    }
                    return admission.isCurrent()
                }
                return completion(await Model.runBatch(records: [1], destination: .nativeShare, action: .systemShare,
                    admission: source, originals: originals(facts), exporter: exporter(facts), share: { .init(urls: $0) },
                    photos: nil, internet: Optional<MonitorDeliveryInternetService<Int>>.none,
                    filename: { "\($0)" }, progress: progress))
            }
            await settle { gate.count == 1 }
            #expect(facts.calls.isEmpty && model.state.running && model.state.progress?.clipFraction == 0.6)
            gate.release(.init(.savedToPhotos(count: 1)))
            await settle { !model.state.running }; model.close()
        }
    }
    @Test func shareStageReentryReleasesOnlyReturnedOldLease() async {
        let facts = DeliveryBatchFacts(); facts.cached = [1]
        let gate = DeliveryBatchGate<MonitorDeliveryCompletion<Outcome, String>>()
        var released: [String] = []
        let model = Model(releaseShare: { released.append($0) })
        model.beginAdmitted { progress, admission in
            return completion(await Model.runBatch(records: [1], destination: .nativeShare, action: .systemShare,
                admission: admission, originals: originals(facts), exporter: exporter(facts), share: { urls in
                    model.begin { _ in await gate.value() }
                    return .init(urls: urls, cleanup: "old staging")
                }, photos: nil, internet: Optional<MonitorDeliveryInternetService<Int>>.none,
                filename: { "\($0)" }, progress: progress))
        }
        await settle { gate.count == 1 && released == ["old staging"] }
        #expect(model.state.running && model.state.share == nil)
        gate.release(.init(.savedToPhotos(count: 1), share: "new staging"))
        await settle { model.state.share?.payload == "new staging" }
        model.close(); #expect(released == ["old staging", "new staging"])
    }
    @Test func transferredInternetLeaseWaitsAndRestoresExactlyOnce() async {
        let facts = DeliveryBatchFacts(); facts.cached = [1]
        var owned: Int? = 7, began = 0, waited: [Int] = [], restored: [Int] = []
        let internet = MonitorDeliveryInternetService<Int>(needsHop: { true }, begin: { began += 1; owned = 9; return 9 },
            owns: { owned == $0 }, wait: { waited.append($0); return true }, restore: { lease in
                if owned == lease { restored.append(lease); owned = nil }
            })
        let outcome = await Model.runBatch(records: [1], destination: .remoteUpload, action: .systemShare,
            admission: .init { true }, originals: originals(facts), exporter: exporter(facts), share: nil,
            photos: nil, upload: .init { _, _ in }, internet: internet, lease: 7,
            filename: { "\($0)" }, progress: { facts.progress.append($0) })
        guard case .uploaded(let summary) = outcome else { Issue.record("Missing admitted upload"); return }
        #expect(summary == "1 uploaded" && began == 0 && waited == [7] && restored == [7])
        #expect(owned == nil)
    }
}
