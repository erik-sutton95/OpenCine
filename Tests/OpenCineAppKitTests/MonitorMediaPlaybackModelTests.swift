import Foundation
import Observation
import OpenCineAppKit
import OpenCineCore
import OpenCineMedia
import Testing

@MainActor private final class PlaybackTestPort: MonitorPlaybackPort {
    var onEvent: (@MainActor @Sendable (MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Void)?
    struct Preparation { let token: MonitorPlaybackItemToken; let continuation: CheckedContinuation<MonitorPlaybackMetadata, Error> }
    struct Seek { let token: MonitorPlaybackItemToken; let target: Double; let tolerance: Double; let continuation: CheckedContinuation<Bool, Never> }
    var preparations: [Preparation] = []
    var seeks: [Seek] = []
    var played: [MonitorPlaybackItemToken] = []
    var retired: [MonitorPlaybackItemToken] = []
    var closes = 0
    var onPause: (@MainActor () -> Void)?
    var emitsInstallation = false
    var onRetire: (@MainActor (MonitorPlaybackItemToken) -> Void)?
    var onSeekReturn: (@MainActor (MonitorPlaybackItemToken) -> Void)?
    func retireItem(for token: MonitorPlaybackItemToken) { retired.append(token); onRetire?(token) }
    func prepare(_ item: MonitorPlaybackItem, token: MonitorPlaybackItemToken, readyTimeout: Duration?) async throws -> MonitorPlaybackMetadata {
        try await withCheckedThrowingContinuation {
            preparations.append(.init(token: token, continuation: $0))
            if emitsInstallation { onEvent?(token, .itemInstalled) }
        }
    }
    func release(_ index: Int, facts: MonitorPlaybackMetadata = .init(duration: 100, conform: .init(captureRate: 120))) { preparations[index].continuation.resume(returning: facts) }
    func play(rate: Double, token: MonitorPlaybackItemToken) { played.append(token) }
    func pause(token: MonitorPlaybackItemToken) { onPause?() }
    func seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken) async -> Bool {
        let completed: Bool = await withCheckedContinuation { seeks.append(.init(token: token, target: seconds, tolerance: tolerance, continuation: $0)) }
        onSeekReturn?(token)
        return completed
    }
    func finishSeek(_ index: Int, completed: Bool = true) { seeks[index].continuation.resume(returning: completed) }
    func setMuted(_ muted: Bool, token: MonitorPlaybackItemToken) {}
    func close(token: MonitorPlaybackItemToken) { if retired.last?.owner == token.owner { closes += 1; onEvent = nil } }
}
@MainActor private final class PlaybackTestCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    var loaded: [MonitorMediaRecord<String>] = []
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { loaded }
    func encode(_ records: [MonitorMediaRecord<String>]) -> Data { Data() }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<String> { throw MediaServiceError.unsupported }
}
@MainActor private final class PlaybackTestFavorites: MonitorMediaFavoritesStore {
    func favorites() -> Set<String> { [] }
    func saveFavorites(_ keys: Set<String>) {}
}
@MainActor private final class PlaybackLookResolver {
    var pending: [CheckedContinuation<MonitorPlaybackLook<String>?, Never>] = []
    func resolve() async -> MonitorPlaybackLook<String>? {
        await withCheckedContinuation { pending.append($0) }
    }
    func release(_ index: Int, _ source: String) { pending[index].resume(returning: .init(transfer: .ilog, source: source)) }
}
@MainActor private final class PlaybackByteTransfer {
    var pending: [CheckedContinuation<Void, Never>] = []
    func transfer(_ sink: any MediaByteSink) async throws -> MediaTransferReceipt {
        let byte = UInt8(pending.count * 2 + 1)
        try await sink.write(Data([byte]))
        await withCheckedContinuation { pending.append($0) }
        try await sink.write(Data([byte + 1]))
        return .init(byteCount: 2, expectedByteCount: 2)
    }
    func release(_ index: Int) { pending[index].resume() }
}
@MainActor private final class PlaybackEmptyCursor: MediaCatalogCursor {
    func next() async -> MediaCatalogDelta? { nil }
    func close() {}
}
@MainActor private final class PlaybackBrowse: CameraMediaBrowse {
    let binding = MediaBrowseBinding(session: .init(), epoch: .init(1))
    var thumbnails: (any CameraMediaThumbnailService)? { nil }
    var transfers: (any CameraMediaTransferService)? { nil }
    var deletion: (any CameraMediaDeleteService)? { nil }
    func catalog() async -> any MediaCatalogCursor { PlaybackEmptyCursor() }
    func close() async {}
}
@MainActor private final class PlaybackService: CameraMediaService {
    let browse = PlaybackBrowse()
    var sessionID: CameraSessionID { browse.binding.session }
    func openBrowse() async -> any CameraMediaBrowse { browse }
}
@MainActor private final class PlaybackTestClock { var instant = MonotonicInstant(.seconds(100)) }
@MainActor private final class PlaybackReplacement { var fired = false }
@MainActor private final class PlaybackResumeProbe {
    var observing = false
    var observations = 0
    var reentered = false
    var atObservation: (@MainActor (Int) -> Void)?
    func current() -> Bool {
        if observing { observations += 1; atObservation?(observations) }
        return true
    }
}

@MainActor @Suite struct MonitorMediaPlaybackModelTests {
    private func record(_ id: String) -> MonitorMediaRecord<String> {
        .init(asset: .init(id: .init(id), filename: id + ".mov", kind: .video, durationSeconds: 100,
            frameRate: 120, representations: []), payload: id,
            address: .init(thumbnail: id + ".jpg", representations: [:], favoriteKey: id))
    }
    @available(macOS 14, *) private func fixture(clock: PlaybackTestClock = .init(), native: PlaybackTestPort? = nil,
        lookTiming: MonitorPlaybackLookTiming = .afterNativeReadiness,
        startTiming: MonitorPlaybackStartTiming = .afterNativeReadiness,
        records: [MonitorMediaRecord<String>] = [], service: (any CameraMediaService)? = nil,
        seekEndClearance: Double = 0.05,
        sceneLossPolicy: MonitorPlaybackSceneLossPolicy? = nil,
        candidate: (@MainActor @Sendable (MonitorMediaRecord<String>) -> [MonitorPlaybackCandidate])? = nil,
        resolveLook: @escaping @MainActor @Sendable (MonitorMediaRecord<String>, MonitorPlaybackItem) async -> MonitorPlaybackLook<String>? = { _, _ in nil }) ->
        (URL, MonitorMediaLibraryModel<String>, PlaybackTestPort, MonitorMediaPlaybackModel<String, String>) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codec = PlaybackTestCodec(); codec.loaded = records
        let cache = MonitorMediaCache(directory: .init(root: root), codec: codec, eligibility: .exactSize,
            catalogAddress: "index.json", preservedMetadata: ["index.json"])
        try! cache.directory.write(Data("[]".utf8), at: "index.json")
        let library = MonitorMediaLibraryModel(cache: cache, favorites: PlaybackTestFavorites(), service: service)
        library.begin()
        let port = native ?? PlaybackTestPort()
        let candidates = candidate ?? {
            [.cached(.init(url: URL(fileURLWithPath: "/" + $0.payload + ".mov"),
                mimeType: "video/mp4", sourceKey: $0.payload))]
        }
        let model = if let sceneLossPolicy {
            MonitorMediaPlaybackModel<String, String>(library: library, native: port, lookTiming: lookTiming,
                startTiming: startTiming, candidates: candidates, resolveLook: resolveLook,
                now: { clock.instant }, seekEndClearance: seekEndClearance,
                sceneLossPolicy: sceneLossPolicy)
        } else {
            MonitorMediaPlaybackModel<String, String>(library: library, native: port, lookTiming: lookTiming,
                startTiming: startTiming, candidates: candidates, resolveLook: resolveLook,
                now: { clock.instant }, seekEndClearance: seekEndClearance)
        }
        return (root, library, port, model)
    }
    private func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<500 { if predicate() { return true }; await Task.yield() }; return predicate()
    }
    @available(macOS 14, *) private func resumeProbe(
        _ model: MonitorMediaPlaybackModel<String, String>, _ port: PlaybackTestPort
    ) -> PlaybackResumeProbe {
        let probe = PlaybackResumeProbe()
        model.setItemAdmission { _ in MonitorPlaybackAdmission { probe.current() } }
        port.onSeekReturn = { _ in probe.observing = true }
        return probe
    }

    /// The playback page reads previous/next availability on every body pass, and a camera
    /// card playlist holds thousands of records (build 317: a full playlist scan per read).
    /// The answer stays right at both ends and its cost does not grow with the playlist.
    @Test func adjacentAvailabilityDoesNotScanThePlaylist() {
        guard #available(macOS 14, *) else { return }
        func cost(playlistSize: Int, reads: Int) -> (Duration, [Bool]) {
            let (root, library, _, model) = fixture()
            defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
            let rows = (0..<playlistSize).map { record("clip\($0)") }
            var edges: [Bool] = []
            for row in [rows[0], rows[playlistSize / 2], rows[playlistSize - 1]] {
                model.load(row, playlist: rows, play: false)
                edges += [model.canGoPrevious, model.canGoNext]
            }
            let clock = ContinuousClock()
            let elapsed = clock.measure {
                for _ in 0..<reads { _ = model.canGoPrevious && model.canGoNext }
            }
            return (elapsed, edges)
        }
        let (small, smallEdges) = cost(playlistSize: 8, reads: 2_000)
        let (large, largeEdges) = cost(playlistSize: 8_000, reads: 2_000)
        #expect(smallEdges == [false, true, true, true, true, false])
        #expect(largeEdges == smallEdges)
        // A scan makes the large playlist about a thousand times dearer; a stored place keeps
        // both within noise of each other.
        #expect(large < small * 20 + .milliseconds(20), "8 records: \(small), 8000 records: \(large)")
    }

    @Test func pendingLoopSeekCompletionCannotOverrideOperatorPause() async {
        guard #available(macOS 14, *) else { return }
        let (root, library, port, model) = fixture(lookTiming: .beforeNativePreparation)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let probe = resumeProbe(model, port), row = record("loop")
        model.load(row, playlist: [row]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready && port.played.count == 1 })
        let item = model.token
        model.setLooping(true); port.onEvent?(item, .ended)
        #expect(await eventually { port.seeks.count == 1 })
        model.setPlaying(false)
        #expect(!model.playRequested && port.seeks.count == 1)
        port.finishSeek(0); #expect(await eventually { probe.observations > 0 })
        #expect(!model.playRequested && port.played == [item])
        #expect(port.seeks[0].token == item && port.seeks[0].target == 0 && port.seeks[0].tolerance == 0)
        #expect(model.ready && model.token == item && port.closes == 0 && library.browsing)
    }

    @Test func pendingRestartSeekCompletionCannotOverrideRepeatedPause() async {
        guard #available(macOS 14, *) else { return }
        let (root, library, port, model) = fixture(lookTiming: .beforeNativePreparation)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let probe = resumeProbe(model, port), row = record("restart")
        model.load(row, playlist: [row], play: false); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready })
        let item = model.token
        model.restart(); #expect(await eventually { port.seeks.count == 1 })
        model.setPlaying(false)
        #expect(!model.playRequested)
        port.finishSeek(0); #expect(await eventually { probe.observations > 0 })
        #expect(!model.playRequested && port.played.isEmpty)
        #expect(model.ready && model.token == item && port.seeks[0].token == item && port.closes == 0)
    }

    @Test func explicitRestartWhilePausedStillResumesPlayback() async {
        guard #available(macOS 14, *) else { return }
        let (root, library, port, model) = fixture(lookTiming: .beforeNativePreparation)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let probe = resumeProbe(model, port), row = record("restart")
        model.load(row, playlist: [row], play: false); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready })
        let item = model.token
        model.restart(); #expect(await eventually { port.seeks.count == 1 })
        port.finishSeek(0); #expect(await eventually { probe.observations > 0 })
        #expect(model.playRequested && port.played == [item] && model.token == item)
        #expect(port.seeks[0].target == 0 && port.seeks[0].tolerance == 0 && port.closes == 0)
    }

    @Test func unrelatedPublicationDoesNotInvalidatePendingRestart() async {
        guard #available(macOS 14, *) else { return }
        let (root, library, port, model) = fixture(lookTiming: .beforeNativePreparation)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let probe = resumeProbe(model, port), row = record("restart")
        model.load(row, playlist: [row], play: false); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready })
        let item = model.token
        model.restart(); #expect(await eventually { port.seeks.count == 1 })
        model.setMuted(true); port.onEvent?(item, .playing(false)); port.onEvent?(item, .position(42))
        port.finishSeek(0); #expect(await eventually { probe.observations > 0 })
        #expect(model.playRequested && port.played == [item] && model.muted)
        #expect(model.position == 42 && model.reportedPlaying == false && model.token == item)
    }

    @Test func lateLoopEndAfterPauseCannotRequestPlayback() async {
        guard #available(macOS 14, *) else { return }
        let (root, library, port, model) = fixture(lookTiming: .beforeNativePreparation)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let probe = resumeProbe(model, port), row = record("loop")
        model.load(row, playlist: [row]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready && port.played.count == 1 })
        let item = model.token
        model.setLooping(true); model.setPlaying(false); port.onEvent?(item, .ended)
        #expect(await eventually { port.seeks.count == 1 })
        port.finishSeek(0); #expect(await eventually { probe.observations > 0 })
        #expect(!model.playRequested && model.looping && port.played == [item])
        #expect(port.seeks[0].target == 0 && port.seeks[0].token == item && model.token == item)
    }

    @Test func restartAdmissionPauseCannotBeOverriddenByCompletion() async {
        guard #available(macOS 14, *) else { return }
        let (root, library, port, model) = fixture(lookTiming: .beforeNativePreparation)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let probe = resumeProbe(model, port), row = record("restart")
        model.load(row, playlist: [row], play: false); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready })
        probe.atObservation = { _ in
            probe.atObservation = nil; probe.reentered = true; model.setPlaying(false)
        }
        probe.observing = true; model.restart(); probe.observing = false; probe.observations = 0
        #expect(probe.reentered)
        #expect(await eventually { port.seeks.count == 1 })
        port.finishSeek(0); #expect(await eventually { probe.observations > 0 })
        #expect(!model.playRequested && port.played.isEmpty && model.ready)
    }

    @Test func resumeAdmissionPauseCannotStartNativeTransport() async {
        guard #available(macOS 14, *) else { return }
        let (root, library, port, model) = fixture(lookTiming: .beforeNativePreparation)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let probe = resumeProbe(model, port), row = record("restart")
        model.load(row, playlist: [row], play: false); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready })
        model.restart(); #expect(await eventually { port.seeks.count == 1 })
        probe.atObservation = { _ in
            if model.playRequested {
                probe.atObservation = nil; probe.reentered = true; model.setPlaying(false)
            }
        }
        port.finishSeek(0); #expect(await eventually { probe.observations > 0 })
        #expect(probe.reentered && !model.playRequested && port.played.isEmpty)
    }

    @Test func clearRequestSceneLossDuringResumeAdmissionCannotStartNativeTransport() async {
        guard #available(macOS 14, *) else { return }
        let (root, library, port, model) = fixture(lookTiming: .beforeNativePreparation, sceneLossPolicy: .clearRequest)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let probe = resumeProbe(model, port), row = record("restart")
        model.load(row, playlist: [row], play: false); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready })
        let item = model.token
        model.restart(); #expect(await eventually { port.seeks.count == 1 })
        probe.atObservation = { _ in
            if model.playRequested {
                probe.atObservation = nil; probe.reentered = true
                model.setSceneActive(false); model.setSceneActive(true)
            }
        }
        port.finishSeek(0); #expect(await eventually { probe.observations > 0 })
        #expect(probe.reentered && !model.playRequested && port.played.isEmpty)
        #expect(model.ready && model.token == item && port.closes == 0 && library.browsing)
    }

    @Test func interruptedScrubDeferredResumeCannotOverrideLaterPause() async {
        guard #available(macOS 14, *) else { return }
        let (root, library, port, model) = fixture(lookTiming: .beforeNativePreparation)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let probe = resumeProbe(model, port), row = record("scrub")
        model.load(row, playlist: [row]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready && port.played.count == 1 })
        let item = model.token
        #expect(model.beginScrub() != nil)
        model.cancelScrub(interrupted: true); model.setPlaying(false); probe.observing = true
        #expect(await eventually { probe.observations > 0 })
        #expect(!model.scrubbing && !model.playRequested && port.played == [item])
        #expect(model.token == item && port.seeks.isEmpty && port.closes == 0 && library.browsing)
    }

    @available(macOS 14, *) @Test func replacementRejectsLateReadyAndTimeFromPreviousItem() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"), b = record("B")
        model.load(a, playlist: [a, b]); #expect(await eventually { port.preparations.count == 1 })
        let old = model.token
        model.load(b, playlist: [a, b]); #expect(await eventually { port.preparations.count == 2 })
        let current = model.token; port.release(1); #expect(await eventually { model.ready })
        port.onEvent?(current, .position(42)); port.release(0)
        #expect(await eventually { model.position == 42 })
        port.onEvent?(old, .position(7)); port.onEvent?(old, .ended)
        #expect(model.active?.payload == "B" && model.position == 42 && model.playRequested && !model.reachedEnd)
        #expect(port.played == [current])
    }
    @available(macOS 14, *) @Test func retiredFinalSeekCannotResumeReplacement() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"), b = record("B")
        model.load(a, playlist: [a, b]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready })
        let admitted = model.beginScrub()!
        model.updateScrub(seconds: 25, admitted: admitted); #expect(await eventually { port.seeks.count == 1 })
        port.finishSeek(0); model.commitScrub(admitted: admitted)
        #expect(await eventually { port.seeks.count == 2 })
        model.load(b, playlist: [a, b], play: false)
        #expect(await eventually { port.preparations.count == 2 })
        port.release(1); #expect(await eventually { model.ready })
        port.finishSeek(1); await Task.yield()
        #expect(!model.playRequested && port.played == [admitted.item] && model.active?.payload == "B")
    }
    @available(macOS 14, *) @Test func scrubThrottleUsesManualClockAndFinalExactSeek() async {
        let clock = PlaybackTestClock(); let (root, library, port, model) = fixture(clock: clock)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"); model.load(a, playlist: [a]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready })
        let token = model.beginScrub()!
        model.updateScrub(seconds: 10, admitted: token); #expect(await eventually { port.seeks.count == 1 }); port.finishSeek(0)
        clock.instant = clock.instant + .milliseconds(74); model.updateScrub(seconds: 20, admitted: token)
        await Task.yield(); #expect(port.seeks.count == 1 && model.scrubPosition == 20)
        clock.instant = clock.instant + .milliseconds(1); model.updateScrub(seconds: 30, admitted: token)
        #expect(await eventually { port.seeks.count == 2 }); port.finishSeek(1)
        model.commitScrub(admitted: token); #expect(await eventually { port.seeks.count == 3 })
        #expect(port.seeks.map(\.tolerance) == [0.1, 0.1, 0])
        #expect(port.seeks.map(\.target) == [10, 30, 30]); port.finishSeek(2)
    }
    @available(macOS 14, *) @Test func coverAndSceneLossKeepNativeOwnerWithoutResumingInterruptedScrub() async {
        let (root, library, port, model) = fixture(sceneLossPolicy: .preserveRequest)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"); model.load(a, playlist: [a]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready })
        let token = model.token; _ = model.beginScrub(); model.cancelScrub(interrupted: true); model.setSceneActive(false)
        await Task.yield(); #expect(port.played == [token])
        model.setPresentationActive(false); model.setSceneActive(true)
        #expect(model.token == token && port.closes == 0 && library.browsing)
        model.setPresentationActive(true); #expect(port.played == [token, token] && model.ready)
    }
    @available(macOS 14, *) @Test func defaultSceneLossLeavesPlaybackPausedOnForegroundReturn() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let row = record("scene-default")
        model.load(row, playlist: [row]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready && port.played.count == 1 })
        model.setSceneActive(false); await Task.yield()
        #expect(!model.playRequested)
        model.setSceneActive(true); await Task.yield()
        #expect(!model.playRequested)
        #expect(port.played.count == 1, "Returning from the background must not restart playback")
        model.setPlaying(true); await Task.yield()
        #expect(port.played.count == 2)
    }
    @available(macOS 14, *) @Test func firstToggleAfterSceneLossResumesWhenNativeNeverReportedThePause() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let row = record("scene-toggle")
        model.load(row, playlist: [row]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready && port.played.count == 1 })
        let item = model.token
        port.onEvent?(item, .playing(true))
        model.setSceneActive(false); model.setSceneActive(true); await Task.yield()
        #expect(!model.canPause, "A cleared request reads paused until native reports again")
        model.togglePlaying(); await Task.yield()
        #expect(model.playRequested && port.played == [item, item])
    }
    @available(macOS 14, *) @Test func sameItemObserverDuringSceneLossCannotSkipTheNativePause() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let row = record("scene-observer")
        model.load(row, playlist: [row]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready && port.played.count == 1 })
        var pauses = 0
        port.onPause = { pauses += 1 }
        withObservationTracking { _ = model.playRequested } onChange: {
            MainActor.assumeIsolated { model.setLooping(true) }
        }
        model.setSceneActive(false)
        #expect(model.looping && !model.playRequested)
        #expect(pauses == 1, "Losing the scene must still pause the native player")
    }
    @available(macOS 14, *) @Test func closeRejectsLateReadyAndLeavesBorrowedGalleryOpen() async {
        let (root, library, port, model) = fixture()
        defer { library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"); model.load(a, playlist: [a]); #expect(await eventually { port.preparations.count == 1 })
        model.close(); model.close(); port.release(0); await Task.yield()
        #expect(model.closed && !model.ready && port.played.isEmpty && port.closes == 1 && library.browsing)
    }
    @available(macOS 14, *) @Test func replacementRejectsLateResolvedLook() async {
        let resolver = PlaybackLookResolver()
        let (root, library, port, model) = fixture(resolveLook: { _, _ in await resolver.resolve() })
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"), b = record("B")
        model.load(a, playlist: [a, b]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { resolver.pending.count == 1 })
        model.load(b, playlist: [a, b]); #expect(await eventually { port.preparations.count == 2 })
        port.release(1); #expect(await eventually { resolver.pending.count == 2 })
        resolver.release(1, "B"); #expect(await eventually { model.look?.source == "B" })
        resolver.release(0, "A"); await Task.yield()
        #expect(model.look?.source == "B" && model.active?.payload == "B")
    }
    @available(macOS 14, *) @Test func newerLookRequestRetiresOlderResolutionOnSameItem() async {
        let resolver = PlaybackLookResolver()
        let (root, library, port, model) = fixture(resolveLook: { _, _ in await resolver.resolve() })
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"); model.load(a, playlist: [a]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { resolver.pending.count == 1 })
        let token = model.token; model.refreshTransfer(); #expect(await eventually { resolver.pending.count == 2 })
        resolver.release(1, "current"); #expect(await eventually { model.look?.source == "current" })
        resolver.release(0, "old"); await Task.yield()
        #expect(model.token == token && model.look?.source == "current")
    }

    @available(macOS 14, *) @Test func offlineLibraryReplacementRejectsPendingLoadWithoutClosingSuccessorPlayer() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"), b = record("B")
        model.load(a, playlist: [a]); #expect(await eventually { port.preparations.count == 1 })
        let oldLifetime = library.lifetimeToken
        library.bind(nil)
        #expect(library.lifetimeToken != oldLifetime && library.browsing && library.binding == nil)
        let (otherRoot, otherLibrary, _, successor) = fixture(native: port)
        defer { successor.close(); otherLibrary.close(); try? FileManager.default.removeItem(at: otherRoot) }
        successor.load(b, playlist: [b]); #expect(await eventually { port.preparations.count == 2 && model.closed })
        port.release(1); #expect(await eventually { successor.ready })
        let current = successor.token
        port.release(0); model.setPlaying(true); port.onEvent?(current, .position(33))
        await Task.yield()
        #expect(!model.ready && successor.position == 33 && successor.active?.payload == "B")
        #expect(port.closes == 0 && port.played == [current])
    }
    @available(macOS 14, *) @Test func offlineLibraryReopenRejectsPendingLook() async {
        let resolver = PlaybackLookResolver()
        let (root, library, port, model) = fixture(resolveLook: { _, _ in await resolver.resolve() })
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"); model.load(a, playlist: [a]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { resolver.pending.count == 1 })
        let oldLifetime = library.lifetimeToken; library.close(); library.begin()
        #expect(library.lifetimeToken != oldLifetime && library.browsing)
        #expect(await eventually { model.closed }); resolver.release(0, "retired")
        await Task.yield(); #expect(model.look == nil && port.closes == 1 && library.browsing)
    }
    @available(macOS 14, *) @Test func offlineLibraryReplacementRejectsPendingFinalSeekAndNativeEvents() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"); model.load(a, playlist: [a]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready })
        let token = model.beginScrub()!; model.updateScrub(seconds: 24, admitted: token)
        #expect(await eventually { port.seeks.count == 1 }); port.finishSeek(0)
        model.commitScrub(admitted: token); #expect(await eventually { port.seeks.count == 2 })
        let nativeEvent = port.onEvent
        library.bind(nil); model.setPlaying(true); model.setMuted(true); nativeEvent?(token.item, .position(81)); nativeEvent?(token.item, .ended)
        #expect(await eventually { model.closed }); port.finishSeek(1); await Task.yield()
        #expect(model.position == 24 && !model.reachedEnd && !model.muted && port.played == [token.item] && library.browsing)
    }

    @available(macOS 14, *) @Test func nativePlayingReportControlsToggleAndScrubWithoutBecomingIntent() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"), b = record("B"); model.load(a, playlist: [a, b])
        #expect(await eventually { port.preparations.count == 1 }); port.release(0)
        #expect(await eventually { model.ready }); let token = model.token
        port.onEvent?(token, .playing(false))
        #expect(model.playRequested && model.reportedPlaying == false)
        model.togglePlaying(); #expect(port.played == [token, token])
        let scrub = model.beginScrub()!; model.updateScrub(seconds: 20, admitted: scrub)
        #expect(await eventually { port.seeks.count == 1 }); port.finishSeek(0); model.commitScrub(admitted: scrub)
        #expect(await eventually { port.seeks.count == 2 }); port.finishSeek(1); await Task.yield()
        #expect(port.played == [token, token], "a native-paused scrub cannot invent a resume from play intent")
        model.load(b, playlist: [a, b]); #expect(await eventually { port.preparations.count == 2 })
        port.release(1); #expect(await eventually { model.ready })
        port.onEvent?(token, .playing(true)); #expect(model.reportedPlaying == nil)
        port.onEvent?(model.token, .playing(false)); port.onEvent?(model.token, .playing(nil))
        #expect(model.reportedPlaying == nil && model.playRequested)
    }
    @available(macOS 14, *) @Test func observableReadyRetirementCannotStartNativePlayback() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"); model.load(a, playlist: [a])
        #expect(await eventually { port.preparations.count == 1 })
        withObservationTracking { _ = model.ready } onChange: {
            MainActor.assumeIsolated { library.bind(nil) }
        }
        port.release(0); #expect(await eventually { model.closed })
        #expect(port.played.isEmpty && !model.ready && library.browsing)
    }

    @available(macOS 14, *) @Test func metadataBeforeNativePreparationRejectsRetiredSourceBeforeDecode() async {
        let resolver = PlaybackLookResolver()
        let (root, library, port, model) = fixture(lookTiming: .beforeNativePreparation,
            resolveLook: { _, _ in await resolver.resolve() })
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"), b = record("B"); model.load(a, playlist: [a, b])
        #expect(await eventually { resolver.pending.count == 1 }); #expect(port.preparations.isEmpty)
        model.goToAdjacent(1); #expect(await eventually { resolver.pending.count == 2 })
        resolver.release(0, "retired"); await Task.yield(); #expect(port.preparations.isEmpty)
        resolver.release(1, "B"); #expect(await eventually { port.preparations.count == 1 })
        #expect(model.look?.source == "B" && !model.ready && model.active?.payload == "B")
        #expect(port.preparations[0].token == model.token)
        port.release(0); #expect(await eventually { model.ready })
        #expect(resolver.pending.count == 2 && port.played == [model.token])
    }

    @available(macOS 14, *) @Test func replacementAbortsOnlyItsOwnStreamingWriteAndKeepsSuccessorBytes() async throws {
        let transfer = PlaybackByteTransfer(), a = record("A"), b = record("B")
        let (root, library, port, model) = fixture(records: [a, b], service: PlaybackService(), candidate: { record in
            [.download(address: "shared.mov", mimeType: "video/mp4", sourceKey: record.payload,
                role: .proxy, transfer: { sink in try await transfer.transfer(sink) })]
        })
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        #expect(await eventually { library.binding != nil })
        model.load(a, playlist: [a, b]); #expect(await eventually { transfer.pending.count == 1 })
        model.goToAdjacent(1); #expect(await eventually { transfer.pending.count == 2 })
        transfer.release(0); await Task.yield(); #expect(port.preparations.isEmpty)
        transfer.release(1); #expect(await eventually { port.preparations.count == 1 })
        #expect(try library.cache.directory.read("shared.mov") == Data([3, 4]))
        port.release(0); #expect(await eventually { model.ready })
        #expect(model.item?.sourceKey == "B" && model.active?.payload == "B" && port.played == [model.token])
    }

    @available(macOS 14, *) @Test func relativeSeekKeepsNativeTransportWithoutInventingResumeFromIntent() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"); model.load(a, playlist: [a])
        #expect(await eventually { port.preparations.count == 1 }); port.release(0)
        #expect(await eventually { model.ready }); let token = model.token
        port.onEvent?(token, .playing(false)); port.onEvent?(token, .position(25))
        model.seek(by: 15); #expect(await eventually { port.seeks.count == 1 })
        #expect(port.seeks[0].target == 40 && port.seeks[0].tolerance == 0)
        port.finishSeek(0); await Task.yield()
        #expect(port.played == [token] && model.playRequested && model.reportedPlaying == false)
    }

    @available(macOS 14, *) @Test func nativePauseReplacementCannotStartScrubOnSuccessor() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"), b = record("B"); model.load(a, playlist: [a, b])
        #expect(await eventually { port.preparations.count == 1 }); port.release(0)
        #expect(await eventually { model.ready })
        port.onPause = { port.onPause = nil; model.load(b, playlist: [a, b], play: false) }
        #expect(model.beginScrub() == nil)
        #expect(model.active?.payload == "B" && !model.scrubbing)
        #expect(await eventually { port.preparations.count == 2 }); port.release(1)
        #expect(await eventually { model.ready })
        #expect(!model.scrubbing && !model.playRequested && port.played.count == 1)
    }

    @available(macOS 14, *) @Test func nativeInstallationAndReadinessKeepTheirDistinctTransportTiming() async {
        let port = PlaybackTestPort(); port.emitsInstallation = true
        let (root, library, _, model) = fixture(native: port)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"); model.load(a, playlist: [a])
        #expect(await eventually { port.preparations.count == 1 })
        #expect(model.nativeItemInstalled && !model.ready && port.played.isEmpty)
        port.release(0); #expect(await eventually { model.ready })
        #expect(port.played == [model.token])

        let eagerPort = PlaybackTestPort(); eagerPort.emitsInstallation = true
        let (otherRoot, otherLibrary, _, eager) = fixture(native: eagerPort, startTiming: .afterNativeItemInstallation)
        defer { eager.close(); otherLibrary.close(); try? FileManager.default.removeItem(at: otherRoot) }
        eager.load(a, playlist: [a])
        #expect(await eventually { eagerPort.preparations.count == 1 })
        #expect(eager.nativeItemInstalled && !eager.ready && eagerPort.played == [eager.token])
        eagerPort.release(0); #expect(await eventually { eager.ready })
        #expect(eagerPort.played == [eager.token], "readiness cannot start the already-started native item again")
    }

    @available(macOS 14, *) @Test func observableActiveReplacementKeepsSuccessorSnapshotAndNativeRequest() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"), b = record("B")
        let replacement = PlaybackReplacement()
        withObservationTracking { _ = model.active } onChange: {
            MainActor.assumeIsolated {
                guard !replacement.fired else { return }; replacement.fired = true
                model.load(b, playlist: [b], play: false)
            }
        }
        model.load(a, playlist: [a])
        #expect(model.active?.payload == "B" && model.playlist.map(\.payload) == ["B"] && !model.playRequested)
        #expect(await eventually { port.preparations.count == 1 })
        #expect(port.preparations[0].token == model.token)
        port.release(0); #expect(await eventually { model.ready })
        #expect(model.active?.payload == "B" && model.item?.sourceKey == "B" && port.played.isEmpty)
    }

    @available(macOS 14, *) @Test func observableReadyReplacementCannotOverwriteSuccessorLoadingSnapshot() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"), b = record("B"); model.load(a, playlist: [a])
        #expect(await eventually { port.preparations.count == 1 })
        let replacement = PlaybackReplacement()
        withObservationTracking { _ = model.ready } onChange: {
            MainActor.assumeIsolated {
                guard !replacement.fired else { return }; replacement.fired = true
                model.load(b, playlist: [b], play: false)
            }
        }
        port.release(0)
        #expect(await eventually { port.preparations.count == 2 })
        #expect(model.active?.payload == "B" && !model.ready && model.loading && model.item?.sourceKey == "B")
        #expect(port.preparations[1].token == model.token && port.played.isEmpty)
        port.release(1); #expect(await eventually { model.ready })
        #expect(model.item?.sourceKey == "B" && !model.playRequested && port.played.isEmpty)
    }

    @available(macOS 14, *) @Test func observablePlayIntentReplacementCannotStartSuccessorTransport() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"), b = record("B"); model.load(a, playlist: [a], play: false)
        #expect(await eventually { port.preparations.count == 1 }); port.release(0)
        #expect(await eventually { model.ready })
        let replacement = PlaybackReplacement()
        withObservationTracking { _ = model.playRequested } onChange: {
            MainActor.assumeIsolated {
                guard !replacement.fired else { return }; replacement.fired = true
                model.load(b, playlist: [b], play: false)
            }
        }
        model.setPlaying(true)
        #expect(model.active?.payload == "B" && !model.playRequested)
        #expect(await eventually { port.preparations.count == 2 }); port.release(1)
        #expect(await eventually { model.ready })
        #expect(!model.playRequested && model.item?.sourceKey == "B" && port.played.isEmpty)
    }

    @available(macOS 14, *) @Test func nativeRetirementReplacementUsesDistinctSuccessorAuthority() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"), b = record("B")
        port.onRetire = { token in
            if token.revision == 1 {
                port.onRetire = nil
                model.load(b, playlist: [b], play: false)
            }
        }
        model.load(a, playlist: [a])
        #expect(model.token.revision == 2 && model.active?.payload == "B" && !model.playRequested)
        #expect(await eventually { port.preparations.count == 1 })
        #expect(port.preparations[0].token == model.token)
        port.release(0); #expect(await eventually { model.ready })
        #expect(model.item?.sourceKey == "B" && port.played.isEmpty)
    }

    @available(macOS 14, *) @Test func metadataAfterReadinessPreservesKnownCaptureRateAndRejectsOldItem() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"), b = record("B"); model.load(a, playlist: [a, b])
        #expect(await eventually { port.preparations.count == 1 })
        port.release(0, facts: .init(duration: 100))
        #expect(await eventually { model.ready && port.played.count == 1 })
        let old = model.token; model.setConformTarget(30)
        port.onEvent?(old, .metadata(.init(duration: 80, width: 640, height: 360)))
        #expect(model.ready && model.metadata.width == 640 && model.duration == 80)
        #expect(model.metadata.conform.captureRate == 120 && model.conformTarget == 30 && model.rate == 0.25)
        model.load(b, playlist: [a, b], play: false)
        let current = model.token
        port.onEvent?(old, .metadata(.init(duration: 7, width: 7, height: 7)))
        #expect(model.token == current && model.active?.payload == "B" && !model.ready && model.duration == 100)
        #expect(await eventually { port.preparations.count == 2 })
        port.release(1); #expect(await eventually { model.ready })
        #expect(model.item?.sourceKey == "B" && model.metadata.width == nil && !model.playRequested)
    }

    @available(macOS 14, *) @Test func refusedFinalSeekCannotResumePausedNativeTransport() async {
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"); model.load(a, playlist: [a])
        #expect(await eventually { port.preparations.count == 1 }); port.release(0)
        #expect(await eventually { model.ready && port.played.count == 1 })
        let edit = model.beginScrub()!
        model.updateScrub(seconds: 30, admitted: edit)
        #expect(await eventually { port.seeks.count == 1 }); port.finishSeek(0)
        model.commitScrub(admitted: edit)
        #expect(await eventually { port.seeks.count == 2 }); port.finishSeek(1, completed: false)
        for _ in 0..<20 { await Task.yield() }
        #expect(port.played.count == 1 && model.ready && !model.scrubbing)
    }

    @available(macOS 14, *) @Test func canceledEditCannotUpdateOrCommitNewEditOnSameItem() async {
        let clock = PlaybackTestClock()
        let (root, library, port, model) = fixture(clock: clock)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"); model.load(a, playlist: [a])
        #expect(await eventually { port.preparations.count == 1 }); port.release(0)
        #expect(await eventually { model.ready })
        let old = model.beginScrub()!; model.cancelScrub(interrupted: false)
        let current = model.beginScrub()!
        model.updateScrub(seconds: 40, admitted: current)
        #expect(await eventually { port.seeks.count == 1 }); port.finishSeek(0)
        clock.instant = clock.instant + .milliseconds(75)
        model.updateScrub(seconds: 7, admitted: old)
        model.commitScrub(admitted: old)
        model.cancelScrub(interrupted: false, admitted: old)
        for _ in 0..<20 { await Task.yield() }
        let retained = model.scrubbing && model.scrubPosition == 40 && port.seeks.count == 1
        #expect(retained)
        guard retained else {
            for index in 1..<port.seeks.count { port.finishSeek(index, completed: false) }
            return
        }
        model.updateScrub(seconds: 55, admitted: current)
        #expect(await eventually { port.seeks.count >= 2 }); port.finishSeek(1)
        #expect(model.scrubbing && model.scrubPosition == 55)
        model.commitScrub(admitted: current)
        #expect(await eventually { port.seeks.count >= 3 }); port.finishSeek(2)
    }



    @available(macOS 14, *) @Test func outgoingBeginCannotAdoptReplacementEditFromNativePause() async throws {
        let clock = PlaybackTestClock()
        let (root, library, port, model) = fixture(clock: clock)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"); model.load(a, playlist: [a])
        #expect(await eventually { port.preparations.count == 1 }); port.release(0)
        #expect(await eventually { model.ready })
        var retired: MonitorPlaybackScrubToken?
        var successor: MonitorPlaybackScrubToken?
        port.onPause = {
            port.onPause = nil
            retired = model.beginScrub()
            model.cancelScrub(interrupted: false)
            successor = model.beginScrub()
            if let successor { model.updateScrub(seconds: 44, admitted: successor) }
        }
        let outgoing = model.beginScrub()
        let kept = try #require(successor), old = try #require(retired)
        #expect(outgoing == nil)
        #expect(kept != old && kept.item == old.item && kept.item == model.token)
        #expect(model.beginScrub() == kept && model.scrubbing && model.scrubPosition == 44)
        #expect(await eventually { port.seeks.count == 1 }); port.finishSeek(0)
        clock.instant = clock.instant + .milliseconds(75)
        model.updateScrub(seconds: 55, admitted: kept)
        #expect(await eventually { port.seeks.count == 2 }); port.finishSeek(1)
        #expect(model.scrubbing && model.scrubPosition == 55)
        model.commitScrub(admitted: kept)
        #expect(await eventually { port.seeks.count == 3 }); port.finishSeek(2)
    }
    @Test func sourceSeekClearancePreservesStrict250msTailAndDefault50msTail() async {
        guard #available(macOS 14, *) else { return }
        for clearance in [0.25, 0.05] {
            let (root, library, port, model) = fixture(seekEndClearance: clearance)
            defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
            let row = record("tail")
            model.load(row, playlist: [row]); #expect(await eventually { port.preparations.count == 1 })
            port.release(0, facts: .init(duration: 10)); #expect(await eventually { model.ready })
            let token = model.token
            let cases: [(Double, Bool)] = clearance == 0.25
                ? [(-0.1, true), (-0.2, true), (-0.25, true), (-0.251, false)]
                : [(-0.025, true), (-0.05, true), (-0.051, false)]
            for (index, value) in cases.enumerated() {
                port.onEvent?(token, .ended); #expect(model.reachedEnd)
                model.seek(by: value.0); #expect(model.reachedEnd == value.1)
                #expect(await eventually { port.seeks.count == index + 1 }); port.finishSeek(index)
                await Task.yield()
            }
        }
    }

    @Test func sourceScrubClearanceRetainsTailUntilStrictBoundaryAndRejectsRetiredEdit() async {
        guard #available(macOS 14, *) else { return }
        let (root, library, port, model) = fixture(seekEndClearance: 0.25)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("tail"), b = record("next")
        model.load(a, playlist: [a, b]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0, facts: .init(duration: 10)); #expect(await eventually { model.ready })
        port.onEvent?(model.token, .ended)
        guard let edit = model.beginScrub() else { Issue.record("Missing ready scrub"); return }
        model.updateScrub(seconds: 9.8, admitted: edit); #expect(model.reachedEnd)
        model.updateScrub(seconds: 9.75, admitted: edit); #expect(model.reachedEnd)
        model.updateScrub(seconds: 9.749, admitted: edit); #expect(!model.reachedEnd)
        #expect(await eventually { port.seeks.count == 1 }); port.finishSeek(0)
        model.load(b, playlist: [a, b]); #expect(await eventually { port.preparations.count == 2 })
        port.release(1, facts: .init(duration: 10)); #expect(await eventually { model.ready })
        port.onEvent?(model.token, .ended)
        model.updateScrub(seconds: 0, admitted: edit)
        #expect(model.reachedEnd && model.active?.asset.id == b.asset.id && !model.scrubbing)
    }

    @Test func clearingSceneRequestCancelsInterruptedScrubWithoutAutomaticResume() async {
        guard #available(macOS 14, *) else { return }
        let (root, library, port, model) = fixture(sceneLossPolicy: .clearRequest)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let row = record("scene")
        model.load(row, playlist: [row]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready && port.played.count == 1 })
        let item = model.token
        guard let edit = model.beginScrub() else { Issue.record("Missing ready scrub"); return }
        model.updateScrub(seconds: 30, admitted: edit)
        #expect(await eventually { port.seeks.count == 1 })
        model.cancelScrub(interrupted: true)
        model.setSceneActive(false)
        port.finishSeek(0)
        for _ in 0..<20 { await Task.yield() }
        model.setSceneActive(true)
        #expect(model.ready && model.token == item && !model.scrubbing && !model.playRequested)
        #expect(port.played == [item] && port.closes == 0 && library.browsing)
        model.setPlaying(true)
        #expect(model.playRequested && port.played == [item, item])
    }

    @Test func clearingSceneRequestCannotClearReplacementFromStatePublication() async {
        guard #available(macOS 14, *) else { return }
        let (root, library, port, model) = fixture(sceneLossPolicy: .clearRequest)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"), b = record("B")
        model.load(a, playlist: [a, b]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready && port.played.count == 1 })
        let old = model.token
        withObservationTracking { _ = model.playRequested } onChange: {
            MainActor.assumeIsolated { model.load(b, playlist: [a, b], play: true) }
        }
        model.setSceneActive(false)
        #expect(model.active?.payload == "B" && model.playRequested && model.token != old)
        #expect(await eventually { port.preparations.count == 2 })
        port.release(1); #expect(await eventually { model.ready })
        let current = model.token
        #expect(port.played == [old])
        model.setSceneActive(true)
        #expect(model.playRequested && port.played == [old, current] && !model.closed)
    }

    @Test func outgoingSceneLossCannotBorrowReplacementFromSourcePredicate() async {
        guard #available(macOS 14, *) else { return }
        let (root, library, port, model) = fixture(sceneLossPolicy: .clearRequest)
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"), b = record("B")
        let replacement = PlaybackReplacement()
        model.setItemAdmission { row in
            MonitorPlaybackAdmission {
                if row.payload == "A", replacement.fired {
                    replacement.fired = false
                    model.load(b, playlist: [a, b], play: true)
                }
                return true
            }
        }
        model.load(a, playlist: [a, b]); #expect(await eventually { port.preparations.count == 1 })
        port.release(0); #expect(await eventually { model.ready && port.played.count == 1 })
        let old = model.token
        replacement.fired = true; model.setSceneActive(false)
        #expect(model.active?.payload == "B" && model.playRequested && model.token != old)
        #expect(await eventually { port.preparations.count == 2 })
        port.release(1); #expect(await eventually { model.ready && port.played.count == 2 })
        #expect(port.played == [old, model.token] && !model.closed && library.browsing)
    }

    @Test func waitingTransportKeepsPauseAvailableWithoutClaimingPlayingOrAdvancingTime() async {
        guard #available(macOS 14, *) else { return }
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let row = record("waiting"); model.load(row, playlist: [row])
        #expect(await eventually { port.preparations.count == 1 }); port.release(0)
        #expect(await eventually { model.ready && port.played.count == 1 }); let item = model.token
        port.onEvent?(item, .position(42)); port.onEvent?(item, .transport(.waiting))
        #expect(model.reportedTransport == .waiting && model.reportedPlaying == false)
        #expect(model.playRequested && model.canPause && model.position == 42)
        model.togglePlaying()
        #expect(!model.playRequested && port.played == [item])
        #expect(model.position == 42 && model.token == item && model.ready)
    }

    @Test func waitingTransportScrubRetainsRequestedResumeAfterNativeSeek() async {
        guard #available(macOS 14, *) else { return }
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let row = record("waiting-scrub"); model.load(row, playlist: [row])
        #expect(await eventually { port.preparations.count == 1 }); port.release(0)
        #expect(await eventually { model.ready && port.played.count == 1 }); let item = model.token
        port.onEvent?(item, .transport(.waiting))
        let edit = model.beginScrub(); #expect(edit != nil)
        guard let edit else { return }
        model.commitScrub(admitted: edit)
        #expect(await eventually { port.seeks.count == 1 }); port.finishSeek(0)
        #expect(await eventually { port.played.count == 2 })
        #expect(model.playRequested && port.played == [item, item] && !model.scrubbing)
    }

    @Test func retiredTransportReportCannotChangeSuccessorIntentOrObservation() async {
        guard #available(macOS 14, *) else { return }
        let (root, library, port, model) = fixture()
        defer { model.close(); library.close(); try? FileManager.default.removeItem(at: root) }
        let a = record("A"), b = record("B"); model.load(a, playlist: [a, b])
        #expect(await eventually { port.preparations.count == 1 }); port.release(0)
        #expect(await eventually { model.ready }); let old = model.token
        port.onEvent?(old, .transport(.waiting)); model.load(b, playlist: [a, b], play: false)
        #expect(await eventually { port.preparations.count == 2 }); port.release(1)
        #expect(await eventually { model.ready })
        port.onEvent?(old, .transport(.playing))
        #expect(model.reportedTransport == nil && model.reportedPlaying == nil && !model.playRequested)
        port.onEvent?(model.token, .transport(.paused))
        #expect(model.reportedTransport == .paused && model.reportedPlaying == false && !model.canPause)
        port.onEvent?(model.token, .transport(nil))
        #expect(model.reportedTransport == nil && model.reportedPlaying == nil && !model.canPause)
    }

}
