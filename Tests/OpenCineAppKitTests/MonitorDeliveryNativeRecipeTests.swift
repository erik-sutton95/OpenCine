import Foundation
import OpenCineAppKit
import Testing

@MainActor private final class NativeDeliveryFacts {
    var cached: Set<Int> = []
    var calls: [String] = []
    var progress: [MonitorDeliveryBatchProgress] = []
    var current = true
}
@MainActor private final class NativeDeliveryGate<T: Sendable> {
    private var waiting: [CheckedContinuation<T, Never>] = []
    var count: Int { waiting.count }
    func value() async -> T { await withCheckedContinuation { waiting.append($0) } }
    func release(_ value: T) { waiting.removeFirst().resume(returning: value) }
}

/// SIMULATED native ports; transaction, failure and cleanup policy uses the actual shared run.
@MainActor @Suite struct MonitorDeliveryNativeRecipeTests {
    typealias Outcome = MonitorDeliveryBatchOutcome<String>
    typealias Model = MonitorDeliveryModel<MonitorDeliveryBatchProgress, Outcome, String>

    @Test func photosAuthorizationPrecedesCacheAndEnteredSave() async {
        let facts = NativeDeliveryFacts()
        let outcome = await batch(
            facts, action: .saveToPhotos,
            photos: .init { _ in
                facts.calls.append("save")
                return true
            },
            authorization: .init(
                isPending: { true }, authorize: { facts.calls.append("authorize") }))
        guard case .savedToPhotos(let count) = outcome else {
            Issue.record("Missing Photos result")
            return
        }
        #expect(count == 1)
        #expect(facts.calls == ["authorize", "cache 1", "prepare 1", "save", "release 1"])
        #expect(facts.progress.first?.stage == .awaitingPhotosAccess)
        #expect(facts.progress.first?.statusLine() == "Waiting for Photos access…")
        #expect(
            facts.progress.contains {
                $0.stage == .saving && $0.showsBusySpinner && !$0.isPreparingClip
            })
    }

    @Test func authorizationRefusalDoesNotAcquirePrepareOrSave() async {
        let facts = NativeDeliveryFacts()
        let outcome = await batch(
            facts, action: .saveToPhotos,
            photos: .init { _ in
                facts.calls.append("save")
                return true
            },
            authorization: .init(
                isPending: { false },
                authorize: {
                    facts.calls.append("authorize")
                    throw failure("access denied")
                }))
        guard case .failed(let message) = outcome else {
            Issue.record("Missing access refusal")
            return
        }
        #expect(message == "access denied" && facts.calls == ["authorize"])
    }

    @Test func nativeContinuationKeepsOrderPartialMetadataAndResourceRelease() async {
        let facts = NativeDeliveryFacts()
        facts.cached = [1, 2, 3]
        let outcome = await batch(
            facts, records: [1, 2, 3],
            exporter: .init(release: { facts.calls.append("release \($0)") }) { record, _ in
                facts.calls.append("prepare \(record)")
                if record == 2 { throw failure("second failed") }
                return "\(record)"
            }, metadata: { _ in "metadata" })
        guard case .share(let urls, let text, _) = outcome else {
            Issue.record("Missing partial native result")
            return
        }
        #expect(urls == ["1", "3"] && text == "Prepared 2; 1 failed.\nmetadata")
        #expect(facts.calls == ["prepare 1", "prepare 2", "prepare 3", "release 1", "release 3"])
    }

    /// A2-56: the one policy. Nothing uploaded but some skipped succeeds with its count; a single
    /// item's failure reports that item's own detail.
    @Test func emptyUploadSuccessKeepsSkippedCountAndSingleFailureDetail() async {
        for failed in [false, true] {
            let facts = NativeDeliveryFacts()
            facts.cached = [1]
            let outcome = await batch(
                facts, destination: .remoteUpload,
                exporter: .init { _, _ in
                    if failed { throw failure("detail") }
                    return nil
                }, upload: .init { _, _ in facts.calls.append("upload") })
            if failed {
                guard case .failed(let message) = outcome else {
                    Issue.record("Missing single failure")
                    continue
                }
                #expect(message == "detail")
            } else {
                guard case .uploaded(let summary) = outcome else {
                    Issue.record("Missing valid empty upload")
                    continue
                }
                #expect(summary == "1 skipped")
            }
            #expect(facts.calls.isEmpty)
        }
    }

    /// A2-51: the share completion keeps the "Include metadata" text for the share sheet.
    @Test func shareCompletionCarriesTheMetadataText() {
        let completion = Outcome.share(urls: ["1"], metadataText: "SIMULATED.MOV", stagingCleanupURL: "lease")
            .completion()
        #expect(completion.share?.urls == ["1"] && completion.share?.cleanup == "lease")
        #expect(completion.share?.metadataText == "SIMULATED.MOV")
    }

    /// A2-53: an uploaded record is skipped before any cache or export work unless re-upload is
    /// on; every confirmed upload is recorded.
    @Test func uploadHistorySkipsUploadedRecordsUnlessReuploadIsOn() async {
        let facts = NativeDeliveryFacts()
        var uploaded: Set<Int> = []
        let history = MonitorDeliveryUploadHistory<Int>(
            wasUploaded: { uploaded.contains($0) }, recordUploaded: { uploaded.insert($0) })
        let upload = MonitorDeliveryUploadService<String> { artifact, _ in
            facts.calls.append("upload \(artifact)")
        }
        let first = await batch(facts, destination: .remoteUpload, upload: upload, history: history)
        guard case .uploaded(let summary) = first else {
            Issue.record("Missing first upload")
            return
        }
        #expect(summary == "1 uploaded" && uploaded == [1])
        #expect(facts.calls == ["cache 1", "prepare 1", "upload 1", "release 1"])
        facts.calls = []
        let second = await batch(facts, destination: .remoteUpload, upload: upload, history: history)
        guard case .uploaded(let skipped) = second else {
            Issue.record("Missing skip")
            return
        }
        #expect(skipped == "1 skipped" && facts.calls.isEmpty)
        let forced = await batch(
            facts, destination: .remoteUpload, upload: upload, history: history, reupload: true)
        guard case .uploaded(let again) = forced else {
            Issue.record("Missing re-upload")
            return
        }
        #expect(again == "1 uploaded" && facts.calls == ["prepare 1", "upload 1", "release 1"])
    }

    /// A2-16: a route refused because another hop holds it fails the upload with the internet
    /// failure; nothing is prepared or uploaded.
    @Test func aRefusedRouteFailsTheUploadBeforeAnyExport() async {
        let facts = NativeDeliveryFacts()
        let outcome = await batch(
            facts, destination: .remoteUpload, upload: .init { _, _ in facts.calls.append("upload") },
            internet: .init(
                needsHop: { true }, begin: { nil }, owns: { _ in false }, wait: { _ in true },
                restore: { _ in }))
        guard case .failed(let message) = outcome else {
            Issue.record("Missing refused route")
            return
        }
        #expect(message == MonitorDeliveryBatchPolicy.internetFailure)
        #expect(!facts.calls.contains { $0.hasPrefix("prepare") || $0.hasPrefix("upload") })
    }

    @Test func photosPerItemContinuesAndReportsExactPartialCounts() async {
        let facts = NativeDeliveryFacts()
        facts.cached = [1, 2, 3]
        let outcome = await batch(
            facts, records: [1, 2, 3], action: .saveToPhotos,
            photos: .init { artifact in
                facts.calls.append("save \(artifact)")
                if artifact == "2" { throw failure("insert failed") }
                return artifact == "1"
            })
        guard case .failed(let message) = outcome else {
            Issue.record("Missing aggregate Photos failure")
            return
        }
        #expect(message == "Saved 1; 2 couldn't be saved to Photos.")
        #expect(
            facts.calls == [
                "prepare 1", "prepare 2", "prepare 3", "save 1", "save 2", "save 3", "release 1",
                "release 2", "release 3",
            ])
    }

    @Test func latePreparedArtifactReleasesOnlyItsEnteredLease() async throws {
        let facts = NativeDeliveryFacts()
        facts.cached = [1]
        let entered = NativeDeliveryGate<String>()
        let model = Model()
        let handle = try #require(
            model.beginCaptured { progress, run in
                let outcome = await batch(
                    facts,
                    exporter: .init(release: { facts.calls.append("release \($0)") }) { _, _ in
                        await entered.value()
                    }, admission: .init { run.isCurrent() && facts.current }, progress: progress)
                return .init(outcome)
            })
        await settle { entered.count == 1 }
        facts.current = false
        model.cancel()
        entered.release("old transient")
        await handle.awaitEnteredCleanup()
        #expect(facts.calls == ["release old transient"])
        #expect(!model.state.running && model.state.share == nil)
        model.close()
    }

    @Test func awaitedCleanupCompletesBeforeOutcomeAndOnlyRestoresCapturedLease() async throws {
        let facts = NativeDeliveryFacts()
        facts.cached = [1]
        let cleanup = NativeDeliveryGate<Void>()
        var owned = 7
        let internet = MonitorDeliveryInternetService<Int>(
            needsHop: { true }, begin: { 7 }, owns: { owned == $0 }, wait: { _ in true },
            restoreEntered: { lease in
                if owned == lease {
                    facts.calls.append("restore \(lease)")
                    owned = 0
                }
            }, restore: { _ in facts.calls.append("wrong synchronous restore") })
        let model = Model()
        let handle = try #require(
            model.beginCaptured { progress, admission in
                let outcome = await batch(
                    facts, destination: .remoteUpload,
                    exporter: .init(release: {
                        facts.calls.append("release \($0)")
                        await cleanup.value()
                        facts.calls.append("released")
                    }) { record, _ in "\(record)" },
                    upload: .init { _, _ in facts.calls.append("upload") },
                    internet: internet, admission: admission, progress: progress)
                return .init(outcome)
            })
        await settle { cleanup.count == 1 }
        #expect(model.state.running && facts.calls == ["upload", "release 1"])
        owned = 8
        cleanup.release(())
        await handle.awaitEnteredCleanup()
        #expect(!model.state.running && owned == 8)
        #expect(facts.calls == ["upload", "release 1", "released"])
        model.close()
    }

    @Test func nilExportFactsStayAbsentAndDefaultFactsRemainAvailable() {
        let absent = MonitorDeliveryExportOptions<Int, Int>(
            curves: [], formats: [], lutAvailable: { true }, convertLogAvailable: { nil },
            lutLabel: { nil }, convertHelp: "", convertUnavailableHelp: "",
            bakeExposureAvailable: { nil }, formatsForRemoteUpload: nil,
            filename: { _ in "original.mov" })
        #expect(
            absent.convertLogAvailable() == nil && absent.bakeExposureAvailable() == nil
                && absent.formatsForRemoteUpload == nil)
        let original = MonitorDeliveryExportOptions<Int, Int>(
            curves: [], formats: [], lutAvailable: { true }, convertLogAvailable: { false },
            lutLabel: { nil }, convertHelp: "", convertUnavailableHelp: "",
            filename: { _ in "original.mov" })
        #expect(
            original.convertLogAvailable() == false && original.bakeExposureAvailable() == true
                && original.formatsForRemoteUpload == true)
    }

    @Test func authorizationObservationCannotBorrowAReplacementSource() async {
        for reply in [false, true] {
            let facts = NativeDeliveryFacts()
            let outcome = await batch(
                facts, action: .saveToPhotos, photos: .init { _ in true },
                authorization: .init(
                    isPending: {
                        facts.current = false
                        return reply
                    }, authorize: { facts.calls.append("authorize") }))
            guard case .failed(let message) = outcome else {
                Issue.record("Missing retired source refusal")
                continue
            }
            #expect(message == "Cancelled." && facts.calls.isEmpty)
        }
    }

    private func batch(
        _ facts: NativeDeliveryFacts, records: [Int] = [1],
        destination: MonitorDeliveryDestination = .nativeShare,
        action: MonitorDeliveryPostExportAction = .systemShare,
        exporter: MonitorDeliveryExportService<Int, String>? = nil,
        photos: MonitorDeliveryPhotosService<String>? = nil,
        authorization: MonitorDeliveryPhotosAuthorizationService? = nil,
        upload: MonitorDeliveryUploadService<String>? = nil,
        internet: MonitorDeliveryInternetService<Int>? = nil,
        history: MonitorDeliveryUploadHistory<Int>? = nil, reupload: Bool = false,
        metadata: @escaping @MainActor ([Int]) -> String? = { _ in nil },
        admission: MonitorDeliveryAdmission? = nil,
        progress: @escaping @MainActor (MonitorDeliveryBatchProgress) -> Void = { _ in }
    ) async -> Outcome {
        await Model.runBatch(
            records: records, destination: destination, action: action,
            admission: admission ?? .init { facts.current },
            originals: .init(
                available: { facts.cached.contains($0) },
                acquire: {
                    facts.calls.append("cache \($0)")
                    facts.cached.insert($0)
                }, progress: { _ in nil }),
            exporter: exporter
                ?? .init(release: { facts.calls.append("release \($0)") }) { record, _ in
                    facts.calls.append("prepare \(record)")
                    return "\(record)"
                }, share: { .init(urls: $0) }, photos: photos, photosAuthorization: authorization,
            upload: upload, uploadHistory: history, reupload: reupload, internet: internet,
            filename: { "\($0)" }, metadata: metadata,
            sleep: { _ in throw CancellationError() },
            progress: {
                facts.progress.append($0)
                progress($0)
            })
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "SIMULATED", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func settle(_ predicate: () -> Bool) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("SIMULATED native delivery did not reach its manual gate")
    }
}
