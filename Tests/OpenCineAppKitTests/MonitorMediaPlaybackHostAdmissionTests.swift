import Foundation
import Observation
import OpenCineAppKit
import OpenCineCore
import OpenCineMedia
import Testing

@MainActor private final class HostPlaybackTestPort: MonitorPlaybackPort {
    var onEvent: (@MainActor @Sendable (MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Void)?
    struct Preparation {
        let token: MonitorPlaybackItemToken
        let continuation: CheckedContinuation<MonitorPlaybackMetadata, Error>
    }
    struct Seek {
        let token: MonitorPlaybackItemToken
        let target: Double
        let tolerance: Double
        let continuation: CheckedContinuation<Bool, Never>
    }
    var preparations: [Preparation] = []
    var seeks: [Seek] = []
    var played: [MonitorPlaybackItemToken] = []
    var retired: [MonitorPlaybackItemToken] = []
    var closes = 0
    var onPause: (@MainActor () -> Void)?
    var emitsInstallation = false
    var onRetire: (@MainActor (MonitorPlaybackItemToken) -> Void)?
    func retireItem(for token: MonitorPlaybackItemToken) {
        retired.append(token)
        onRetire?(token)
    }
    func prepare(
        _ item: MonitorPlaybackItem, token: MonitorPlaybackItemToken, readyTimeout: Duration?
    ) async throws -> MonitorPlaybackMetadata {
        try await withCheckedThrowingContinuation {
            preparations.append(.init(token: token, continuation: $0))
            if emitsInstallation { onEvent?(token, .itemInstalled) }
        }
    }
    func release(
        _ index: Int,
        facts: MonitorPlaybackMetadata = .init(duration: 100, conform: .init(captureRate: 120))
    ) { preparations[index].continuation.resume(returning: facts) }
    func play(rate: Double, token: MonitorPlaybackItemToken) { played.append(token) }
    func pause(token: MonitorPlaybackItemToken) { onPause?() }
    func seek(seconds: Double, tolerance: Double, token: MonitorPlaybackItemToken) async -> Bool {
        await withCheckedContinuation {
            seeks.append(
                .init(token: token, target: seconds, tolerance: tolerance, continuation: $0))
        }
    }
    func finishSeek(_ index: Int, completed: Bool = true) {
        seeks[index].continuation.resume(returning: completed)
    }
    func setMuted(_ muted: Bool, token: MonitorPlaybackItemToken) {}
    func close(token: MonitorPlaybackItemToken) {
        if retired.last?.owner == token.owner {
            closes += 1
            onEvent = nil
        }
    }
}
@MainActor private final class HostPlaybackTestCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    var loaded: [MonitorMediaRecord<String>] = []
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { loaded }
    func encode(_ records: [MonitorMediaRecord<String>]) -> Data { Data() }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<
        String
    > { throw MediaServiceError.unsupported }
}
@MainActor private final class HostPlaybackTestFavorites: MonitorMediaFavoritesStore {
    func favorites() -> Set<String> { [] }
    func saveFavorites(_ keys: Set<String>) {}
}
@MainActor private final class HostPlaybackLookResolver {
    var pending: [CheckedContinuation<MonitorPlaybackLook<String>?, Never>] = []
    func resolve() async -> MonitorPlaybackLook<String>? {
        await withCheckedContinuation { pending.append($0) }
    }
    func release(_ index: Int, _ source: String) {
        pending[index].resume(returning: .init(transfer: .ilog, source: source))
    }
}
@MainActor private final class HostPlaybackByteTransfer {
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
@MainActor private final class HostPlaybackEmptyCursor: MediaCatalogCursor {
    func next() async -> MediaCatalogDelta? { nil }
    func close() {}
}
@MainActor private final class HostPlaybackBrowse: CameraMediaBrowse {
    let binding = MediaBrowseBinding(session: .init(), epoch: .init(1))
    var thumbnails: (any CameraMediaThumbnailService)? { nil }
    var transfers: (any CameraMediaTransferService)? { nil }
    var deletion: (any CameraMediaDeleteService)? { nil }
    func catalog() async -> any MediaCatalogCursor { HostPlaybackEmptyCursor() }
    func close() async {}
}
@MainActor private final class HostPlaybackService: CameraMediaService {
    let browse = HostPlaybackBrowse()
    var sessionID: CameraSessionID { browse.binding.session }
    func openBrowse() async -> any CameraMediaBrowse { browse }
}
@MainActor private final class HostPlaybackTestClock {
    var instant = MonotonicInstant(.seconds(100))
}
@MainActor private final class HostPlaybackReplacement { var fired = false }

@MainActor @Observable private final class HostContentGate {
    var a = true
    var b = true
}
@MainActor private final class HostTransferCount { var calls = 0 }
@MainActor private final class HostCommitHook { var body: (@MainActor () -> Void)? }

@MainActor @Suite struct MonitorMediaPlaybackHostAdmissionTests {
    private func record(_ id: String) -> MonitorMediaRecord<String> {
        .init(
            asset: .init(
                id: .init(id), filename: id + ".mov", kind: .video, durationSeconds: 100,
                frameRate: 120, representations: []), payload: id,
            address: .init(thumbnail: id + ".jpg", representations: [:], favoriteKey: id))
    }
    @available(macOS 14, *) private func fixture(
        clock: HostPlaybackTestClock = .init(), native: HostPlaybackTestPort? = nil,
        lookTiming: MonitorPlaybackLookTiming = .afterNativeReadiness,
        startTiming: MonitorPlaybackStartTiming = .afterNativeReadiness,
        records: [MonitorMediaRecord<String>] = [], service: (any CameraMediaService)? = nil,
        candidate: (
            @MainActor @Sendable (MonitorMediaRecord<String>) -> [MonitorPlaybackCandidate]
        )? = nil,
        resolveLook:
            @escaping @MainActor @Sendable (MonitorMediaRecord<String>, MonitorPlaybackItem) async
            -> MonitorPlaybackLook<String>? = { _, _ in nil }
    ) -> (
        URL, MonitorMediaLibraryModel<String>, HostPlaybackTestPort,
        MonitorMediaPlaybackModel<String, String>
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codec = HostPlaybackTestCodec()
        codec.loaded = records
        let cache = MonitorMediaCache(
            directory: .init(root: root), codec: codec, eligibility: .exactSize,
            catalogAddress: "index.json", preservedMetadata: ["index.json"])
        try! cache.directory.write(Data("[]".utf8), at: "index.json")
        let library = MonitorMediaLibraryModel(
            cache: cache, favorites: HostPlaybackTestFavorites(), service: service,
            initialCatalog: .init())
        library.begin()
        let port = native ?? HostPlaybackTestPort()
        let model = MonitorMediaPlaybackModel<String, String>(
            library: library, native: port, lookTiming: lookTiming, startTiming: startTiming,
            candidates: candidate ?? {
                [
                    .cached(
                        .init(
                            url: URL(fileURLWithPath: "/" + $0.payload + ".mov"),
                            mimeType: "video/mp4", sourceKey: $0.payload))
                ]
            },
            resolveLook: resolveLook, now: { clock.instant })
        return (root, library, port, model)
    }
    private func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    @available(macOS 14, *) @Test func hostDownloadWithoutBrowseBindingDoesNotManufactureCatalog()
        async throws
    {
        let a = record("A")
        let (root, library, port, model) = fixture(
            records: [a],
            candidate: { _ in
                [
                    .hostDownload(
                        address: "play/A.mp4", mimeType: "video/mp4", sourceKey: "A", role: .proxy,
                        admission: .init(isCurrent: { true }),
                        transfer: { sink in
                            try await sink.write(Data([1, 2]))
                            return .init(byteCount: 2)
                        })
                ]
            })
        defer {
            model.close()
            library.close()
            try? FileManager.default.removeItem(at: root)
        }
        model.load(a, playlist: [a])
        #expect(await eventually { port.preparations.count == 1 })
        #expect(library.binding == nil && library.catalog.assets.isEmpty && !library.canTransfer)
        #expect(try library.cache.directory.read("play/A.mp4") == Data([1, 2]))
        port.release(0)
        #expect(await eventually { model.ready })
    }
    @available(macOS 14, *) @Test func sourceDownloadStillRequiresBrowseBinding() async {
        let gate = HostTransferCount()
        let a = record("A")
        let (root, library, port, model) = fixture(
            records: [a],
            candidate: { _ in
                [
                    .download(
                        address: "A.mp4", mimeType: "video/mp4", sourceKey: "A", role: .original,
                        transfer: { sink in
                            gate.calls += 1
                            try await sink.write(Data([1]))
                            return .init(byteCount: 1)
                        })
                ]
            })
        defer {
            model.close()
            library.close()
            try? FileManager.default.removeItem(at: root)
        }
        model.load(a, playlist: [a])
        #expect(await eventually { !model.loading })
        #expect(gate.calls == 0 && port.preparations.isEmpty && library.binding == nil)
        #expect(model.error == "This clip is not cached on the phone.")
    }
    @available(macOS 14, *) @Test func retiredHostWriterCannotCommitAfterRootClear() async throws {
        let transfer = HostPlaybackByteTransfer()
        let a = record("A")
        let (root, library, port, model) = fixture(
            records: [a],
            candidate: { _ in
                [
                    .hostDownload(
                        address: "A.mp4", mimeType: "video/mp4", sourceKey: "A", role: .original,
                        admission: .init(isCurrent: { true }),
                        transfer: { try await transfer.transfer($0) })
                ]
            })
        defer {
            model.close()
            library.close()
            try? FileManager.default.removeItem(at: root)
        }
        let directory = library.cache.directory
        let generation = directory.generation
        model.setItemAdmission { _ in .init(isCurrent: { directory.generation == generation }) }
        model.load(a, playlist: [a])
        #expect(await eventually { transfer.pending.count == 1 })
        try await directory.clear(preserving: ["index.json"])
        transfer.release(0)
        #expect(await eventually { model.closed })
        #expect(directory.existing("A.mp4") == nil && port.preparations.isEmpty && port.closes == 1)
    }
    @available(macOS 14, *) @Test func contentAdmissionRejectsLateReadyAndNativeEvents() async {
        let gate = HostContentGate()
        let a = record("A")
        let (root, library, port, model) = fixture(records: [a])
        defer {
            model.close()
            library.close()
            try? FileManager.default.removeItem(at: root)
        }
        model.setItemAdmission { _ in .init(isCurrent: { gate.a }) }
        model.load(a, playlist: [a])
        #expect(await eventually { port.preparations.count == 1 })
        let old = model.token
        let event = port.onEvent
        gate.a = false
        // Ordinary setters notify before their value changes. Final admission is already false;
        // deferred validation retires native ownership after the setter completes.
        #expect(!model.isActive)
        #expect(await eventually { model.closed && port.closes == 1 })
        event?(old, .position(70))
        port.release(0)
        await Task.yield()
        #expect(!model.ready && model.position == 0 && port.played.isEmpty && library.browsing)
    }
    @available(macOS 14, *) @Test func successorCapturesFreshAdmissionAndRejectsOldSeek() async {
        let gate = HostContentGate()
        let a = record("A")
        let b = record("B")
        let (root, library, port, model) = fixture(records: [a, b])
        defer {
            model.close()
            library.close()
            try? FileManager.default.removeItem(at: root)
        }
        model.setItemAdmission { record in
            .init(isCurrent: { record.payload == "A" ? gate.a : gate.b })
        }
        model.load(a, playlist: [a, b])
        #expect(await eventually { port.preparations.count == 1 })
        port.release(0)
        #expect(await eventually { model.ready })
        model.seek(by: 10)
        #expect(await eventually { port.seeks.count == 1 })
        model.load(b, playlist: [a, b], play: false)
        #expect(await eventually { port.preparations.count == 2 })
        gate.a = false
        port.finishSeek(0)
        port.release(1)
        #expect(await eventually { model.ready })
        #expect(
            !model.closed && model.active?.payload == "B" && !model.playRequested
                && model.position == 0)
    }
    @available(macOS 14, *) @Test
    func ordinaryLibraryActionsPreservePlaybackButContentReplacementRetiresIt() async throws {
        let a = record("A")
        let replacement = record("replacement")
        let (root, library, port, model) = fixture(records: [a])
        defer {
            model.close()
            library.close()
            try? FileManager.default.removeItem(at: root)
        }
        model.setItemAdmission { record in
            .init(isCurrent: { library.record(record.asset.id) != nil })
        }
        model.load(a, playlist: [a])
        #expect(await eventually { port.preparations.count == 1 })
        port.release(0)
        #expect(await eventually { model.ready })
        library.resetFilters()
        library.clearSelection()
        library.refreshLocalCache()
        #expect(model.ready && !model.closed && port.closes == 0)
        try library.applyLocalRecords(
            .init(resetLibrary: false, upserts: [replacement], removed: [a.asset.id]),
            token: library.actionToken)
        #expect(!model.isActive)
        #expect(await eventually { model.closed && port.closes == 1 })
        #expect(library.record(replacement.asset.id) != nil)
        #expect(library.catalog.assets.isEmpty && library.binding == nil)
    }
    @available(macOS 14, *) @Test
    func admittedCommitCallbackCannotInstallAnOutgoingItemOverSuccessor() async throws {
        let hook = HostCommitHook()
        let a = record("A")
        let b = record("B")
        let (root, library, port, model) = fixture(
            records: [a, b],
            candidate: { record in
                if record.payload == "B" {
                    return [
                        .cached(
                            .init(
                                url: URL(fileURLWithPath: "/B.mov"), mimeType: "video/mp4",
                                sourceKey: "B"))
                    ]
                }
                return [
                    .hostDownload(
                        address: "A.mp4", mimeType: "video/mp4", sourceKey: "A", role: .original,
                        admission: .init(isCurrent: { true }), didCommit: { hook.body?() },
                        transfer: { sink in
                            try await sink.write(Data([1]))
                            return .init(byteCount: 1)
                        })
                ]
            })
        defer {
            hook.body = nil
            model.close()
            library.close()
            try? FileManager.default.removeItem(at: root)
        }
        hook.body = { model.load(b, playlist: [a, b], play: false) }
        model.load(a, playlist: [a, b])
        #expect(await eventually { port.preparations.count == 1 })
        #expect(model.active?.payload == "B" && model.item?.sourceKey == "B")
        #expect(try library.cache.directory.read("A.mp4") == Data([1]))
        port.release(0)
        #expect(await eventually { model.ready })
        #expect(!model.playRequested && port.played.isEmpty)
    }
}
