import Foundation
import Observation
import OpenCineAppKit
import OpenCineCore
import OpenCineMedia
import Testing

@MainActor private final class HostIOGate {
    var pending: [CheckedContinuation<Void, Never>] = []
    var entered = 0
    func wait() async { entered += 1; await withCheckedContinuation { pending.append($0) } }
    func release() { let held = pending; pending = []; for waiter in held { waiter.resume() } }
}
@MainActor private final class HostIOSleep {
    let gate = HostIOGate()
    var delays: [Duration] = []
    func wait(_ duration: Duration) async { delays.append(duration); await gate.wait() }
}
@MainActor private struct HostIOCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { [] }
    func encode(_ records: [MonitorMediaRecord<String>]) -> Data { Data() }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) -> MonitorMediaRecord<String> {
        .init(asset: asset, payload: asset.filename,
            address: .init(thumbnail: nil, representations: [:], favoriteKey: asset.filename))
    }
}
@MainActor private final class HostIOFavorites: MonitorMediaFavoritesStore {
    func favorites() -> Set<String> { [] }
    func saveFavorites(_ keys: Set<String>) {}
}
@MainActor private final class HostIOCursor: MediaCatalogCursor {
    func next() async -> MediaCatalogDelta? { nil }
    func close() {}
}
@MainActor private final class HostIOBrowse: CameraMediaBrowse {
    let binding = MediaBrowseBinding(session: .init(), epoch: .init(1))
    var thumbnails: (any CameraMediaThumbnailService)? { nil }
    var transfers: (any CameraMediaTransferService)? { nil }
    var deletion: (any CameraMediaDeleteService)? { nil }
    var closes = 0
    func catalog() async -> any MediaCatalogCursor { HostIOCursor() }
    func close() async { closes += 1 }
}
@MainActor private final class HostIOService: CameraMediaService {
    let browse = HostIOBrowse()
    var sessionID: CameraSessionID { browse.binding.session }
    var opens = 0
    func openBrowse() async -> any CameraMediaBrowse { opens += 1; return browse }
}
private enum HostIOAttemptError: Error { case failed }
private actor HostIOBorrowedSink: MediaByteSink {
    var bytes = Data()
    func write(_ chunk: Data) { bytes.append(chunk) }
}
@MainActor @Suite struct MonitorMediaLibraryIOTests {
    private func library(_ sleep: HostIOSleep) -> (URL, MonitorMediaLibraryModel<String>) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = MonitorMediaCache(directory: .init(root: root), codec: HostIOCodec(),
            eligibility: .exactSize, catalogAddress: "index", preservedMetadata: [])
        return (root, .init(cache: cache, favorites: HostIOFavorites(), sleep: { await sleep.wait($0) }))
    }
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<4000 { if condition() { return true }; await Task.yield() }
        return condition()
    }
    private func authority(_ model: MonitorMediaLibraryModel<String>, key: String = "clip")
        -> MonitorMediaLibraryIOAuthority {
        model.captureIO(key: .init(key), asset: nil, ifCurrent: { true })
    }

    private func imageAuthority(_ model: MonitorMediaLibraryModel<String>, id: String = "image") throws
        -> MonitorMediaLibraryIOAuthority {
        let record = HostIOCodec().capture(.init(id: .init(id), filename: "image.jpg", kind: .photo,
            representations: []), binding: HostIOBrowse().binding)
        try model.applyLocalRecords(.init(resetLibrary: false, upserts: [record]), token: model.actionToken)
        return model.captureIO(key: .init("clip"), asset: record.asset.id, ifCurrent: { true })
    }

    @Test func rawOriginalImageRequiresActualRecord() async {
        let clock = HostIOSleep(), (root, model) = library(clock)
        defer { model.close(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        var read = false
        do {
            _ = try await model.readHostOriginalImage(authority(model)) { read = true; return Data([1]) }
            Issue.record("Unindexed original images must not be dispatched")
        } catch let error as MediaServiceError { #expect(error == .unavailable) }
        catch { Issue.record("Unexpected error: \(error)") }
        let removed = model.captureIO(key: .init("clip"), asset: .init("missing"), ifCurrent: { true })
        do {
            _ = try await model.readHostOriginalImage(removed) { read = true; return Data([2]) }
            Issue.record("Missing original image records must not be dispatched")
        } catch let error as MediaServiceError { #expect(error == .retired) }
        catch { Issue.record("Unexpected error: \(error)") }
        #expect(!read && model.records.isEmpty && model.catalog.assets.isEmpty && model.hostProgress.isEmpty)
    }
    @Test func rawOriginalImagePreservesBytesWithoutCacheOrProgress() async throws {
        let clock = HostIOSleep(), (root, model) = library(clock)
        defer { model.close(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let cached = root.appendingPathComponent("original/existing")
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([7]).write(to: cached)
        let captured = try imageAuthority(model)
        #expect(try await model.readHostOriginalImage(captured) { Data([1, 0, 255]) } == Data([1, 0, 255]))
        let empty = try await model.readHostOriginalImage(imageAuthority(model)) { Data() }
        #expect(empty != nil && empty?.isEmpty == true)
        #expect(try Data(contentsOf: cached) == Data([7]))
        #expect(model.records.map(\.asset.id) == [.init("image")])
        #expect(model.hostProgress.isEmpty && clock.delays.isEmpty)
    }
    @Test func rawOriginalImageHasDistinctClaimAndPreservesDownloadProgress() async throws {
        let clock = HostIOSleep(), downloadGate = HostIOGate(), imageGate = HostIOGate(), (root, model) = library(clock)
        defer { model.close(); downloadGate.release(); imageGate.release(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let originalAuthority = try imageAuthority(model)
        let download = Task { try await model.cacheHostFile(authority(model), purpose: .download,
            at: "original/download", expectedByteCount: 2) { sink in
                try await sink.write(Data([7])); await downloadGate.wait()
                try await sink.write(Data([8])); return .init(byteCount: 2)
            } }
        #expect(await eventually { downloadGate.entered == 1 })
        let progress = model.hostProgress
        #expect(progress[.init("clip")] == 0.5)
        let image = Task { try await model.readHostOriginalImage(originalAuthority) { await imageGate.wait(); return Data([9]) } }
        #expect(await eventually { imageGate.entered == 1 })
        var duplicateRead = false
        let duplicate = try await model.readHostOriginalImage(imageAuthority(model)) { duplicateRead = true; return Data([2]) }
        #expect(duplicate == nil && !duplicateRead)
        #expect(try await model.readHostThumbnail(authority(model)) { Data([3]) } == Data([3]))
        #expect(model.hostProgress == progress)
        imageGate.release(); #expect(try await image.value == Data([9]))
        #expect(model.hostProgress == progress)
        downloadGate.release(); #expect(try await download.value != nil)
        #expect(try Data(contentsOf: root.appendingPathComponent("original/download")) == Data([7, 8]))
    }
    @Test func rawOriginalImageCloseCannotPublishOrRetireSuccessor() async throws {
        let clock = HostIOSleep(), oldGate = HostIOGate(), nextGate = HostIOGate(), (root, model) = library(clock)
        defer { model.close(); oldGate.release(); nextGate.release(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let oldAuthority = try imageAuthority(model)
        let old = Task { try? await model.readHostOriginalImage(oldAuthority) { await oldGate.wait(); return Data([1]) } }
        #expect(await eventually { oldGate.entered == 1 })
        model.close(); model.begin()
        let nextAuthority = try imageAuthority(model)
        let next = Task { try await model.readHostOriginalImage(nextAuthority) { await nextGate.wait(); return Data([9]) } }
        #expect(await eventually { nextGate.entered == 1 })
        oldGate.release(); #expect(await old.value == nil)
        var duplicateRead = false
        let duplicate = try await model.readHostOriginalImage(imageAuthority(model)) { duplicateRead = true; return Data([2]) }
        #expect(duplicate == nil && !duplicateRead)
        nextGate.release(); #expect(try await next.value == Data([9]))
        #expect(try await model.readHostOriginalImage(imageAuthority(model)) { Data([8]) } == Data([8]))
        #expect(model.hostProgress.isEmpty)
    }
    @Test func rawOriginalImageCancellationReleasesOnlyItsClaim() async throws {
        let clock = HostIOSleep(), gate = HostIOGate(), (root, model) = library(clock)
        defer { model.close(); gate.release(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let oldAuthority = try imageAuthority(model)
        let old = Task { try? await model.readHostOriginalImage(oldAuthority) { await gate.wait(); return Data([1]) } }
        #expect(await eventually { gate.entered == 1 })
        old.cancel(); gate.release(); #expect(await old.value == nil)
        #expect(try await model.readHostOriginalImage(imageAuthority(model)) { Data([9]) } == Data([9]))
        #expect(model.hostProgress.isEmpty && clock.delays.isEmpty)
    }
    @Test func rawOriginalImageContentRemovalRejectsLateBytes() async throws {
        let clock = HostIOSleep(), gate = HostIOGate(), (root, model) = library(clock)
        defer { model.close(); gate.release(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let oldAuthority = try imageAuthority(model, id: "old")
        let old = Task { try? await model.readHostOriginalImage(oldAuthority) { await gate.wait(); return Data([1]) } }
        #expect(await eventually { gate.entered == 1 })
        try model.applyLocalRecords(.init(resetLibrary: true, upserts: []), token: model.actionToken)
        let nextAuthority = try imageAuthority(model, id: "next")
        gate.release(); #expect(await old.value == nil)
        #expect(try await model.readHostOriginalImage(nextAuthority) { Data([9]) } == Data([9]))
        #expect(model.records.map(\.asset.id) == [.init("next")] && model.hostProgress.isEmpty)
    }
    @Test func rawOriginalImagePredicateReentryCannotDispatchOrEraseSuccessor() async throws {
        let clock = HostIOSleep(), oldGate = HostIOGate(), nextGate = HostIOGate(), (root, model) = library(clock)
        defer { model.close(); oldGate.release(); nextGate.release(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        _ = try imageAuthority(model)
        var outgoing: MonitorMediaLibraryIOAuthority!
        var reenter = false
        var successor: Task<Data?, Error>?
        outgoing = model.captureIO(key: .init("clip"), asset: .init("image")) {
            if reenter {
                reenter = false
                model.close(); model.begin()
                let next = try! imageAuthority(model)
                successor = Task { try await model.readHostOriginalImage(next) { await nextGate.wait(); return Data([9]) } }
            }
            return true
        }
        let old = Task { try? await model.readHostOriginalImage(outgoing) { await oldGate.wait(); return Data([1]) } }
        #expect(await eventually { oldGate.entered == 1 })
        reenter = true; oldGate.release(); #expect(await old.value == nil)
        #expect(await eventually { nextGate.entered == 1 })
        var duplicateRead = false
        let duplicate = try await model.readHostOriginalImage(imageAuthority(model)) { duplicateRead = true; return Data([2]) }
        #expect(duplicate == nil && !duplicateRead)
        nextGate.release(); #expect(try await successor?.value == Data([9]))
        var sent = false, replaceBeforeDispatch = true
        let retired = model.captureIO(key: .init("clip"), asset: .init("image")) {
            if replaceBeforeDispatch { replaceBeforeDispatch = false; model.close(); model.begin() }
            return true
        }
        do {
            _ = try await model.readHostOriginalImage(retired) { sent = true; return Data([3]) }
            Issue.record("A reentered source cannot dispatch an outgoing image")
        } catch {}
        #expect(!sent && model.hostProgress.isEmpty)
    }

    @Test func rawThumbnailPreservesBytesWithoutCacheOrProgress() async throws {
        let clock = HostIOSleep(), (root, model) = library(clock)
        defer { model.close(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let cached = root.appendingPathComponent("thumb/existing")
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([7]).write(to: cached)
        let bytes = try await model.readHostThumbnail(authority(model)) { Data([1, 0, 9]) }
        #expect(bytes == Data([1, 0, 9]))
        #expect(try Data(contentsOf: cached) == Data([7]))
        let empty = try await model.readHostThumbnail(authority(model)) { Data() }
        #expect(empty != nil && empty?.isEmpty == true)
        #expect(model.hostProgress.isEmpty && clock.delays.isEmpty)
        #expect(model.records.isEmpty && model.catalog.assets.isEmpty)
    }
    @Test func rawThumbnailDeduplicatesWithExistingThumbnailOwner() async throws {
        let clock = HostIOSleep(), cacheGate = HostIOGate(), readGate = HostIOGate(), (root, model) = library(clock)
        defer { model.close(); cacheGate.release(); readGate.release(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let cached = Task { try await model.ensureHostThumbnail(authority(model), at: "thumb/a") { await cacheGate.wait(); return Data([7]) } }
        #expect(await eventually { cacheGate.entered == 1 })
        var sent = false
        let refused = try await model.readHostThumbnail(authority(model)) { sent = true; return Data([9]) }
        #expect(refused == nil && !sent)
        cacheGate.release(); try await cached.value
        let raw = Task { try await model.readHostThumbnail(authority(model)) { await readGate.wait(); return Data([3]) } }
        #expect(await eventually { readGate.entered == 1 })
        try await model.ensureHostThumbnail(authority(model), at: "thumb/a") { sent = true; return Data([9]) }
        #expect(!sent)
        readGate.release(); #expect(try await raw.value == Data([3]))
        #expect(try Data(contentsOf: root.appendingPathComponent("thumb/a")) == Data([7]))
        #expect(model.hostProgress.isEmpty)
    }
    @Test func rawThumbnailCloseCannotPublishOrRetireSuccessor() async throws {
        let clock = HostIOSleep(), oldGate = HostIOGate(), nextGate = HostIOGate(), (root, model) = library(clock)
        defer { model.close(); oldGate.release(); nextGate.release(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let oldAuthority = authority(model)
        let old = Task { try? await model.readHostThumbnail(oldAuthority) { await oldGate.wait(); return Data([1]) } }
        #expect(await eventually { oldGate.entered == 1 })
        model.close(); model.begin()
        let next = Task { try await model.readHostThumbnail(authority(model)) { await nextGate.wait(); return Data([9]) } }
        #expect(await eventually { nextGate.entered == 1 })
        oldGate.release(); #expect(await old.value == nil)
        var duplicateSent = false
        let refused = try await model.readHostThumbnail(authority(model)) { duplicateSent = true; return Data([2]) }
        #expect(refused == nil && !duplicateSent)
        nextGate.release(); #expect(try await next.value == Data([9]))
        #expect(try await model.readHostThumbnail(authority(model)) { Data([8]) } == Data([8]))
        #expect(model.hostProgress.isEmpty && model.records.isEmpty && model.catalog.assets.isEmpty)
    }
    @Test func rawThumbnailCancellationReleasesClaimWithoutCache() async throws {
        let clock = HostIOSleep(), gate = HostIOGate(), (root, model) = library(clock)
        defer { model.close(); gate.release(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let old = Task { try? await model.readHostThumbnail(authority(model)) { await gate.wait(); return Data([1]) } }
        #expect(await eventually { gate.entered == 1 })
        old.cancel(); gate.release(); #expect(await old.value == nil)
        #expect(try await model.readHostThumbnail(authority(model)) { Data([9]) } == Data([9]))
        #expect(model.hostProgress.isEmpty && model.records.isEmpty && model.catalog.assets.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("thumb").path))
    }
    @Test func rawThumbnailContentRemovalRejectsLateBytes() async throws {
        let clock = HostIOSleep(), gate = HostIOGate(), (root, model) = library(clock)
        defer { model.close(); gate.release(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let oldRecord = HostIOCodec().capture(.init(id: .init("old"), filename: "clip", representations: []), binding: HostIOBrowse().binding)
        let nextRecord = HostIOCodec().capture(.init(id: .init("next"), filename: "clip", representations: []), binding: HostIOBrowse().binding)
        try model.applyLocalRecords(.init(resetLibrary: true, upserts: [oldRecord]), token: model.actionToken)
        let oldAuthority = model.captureIO(key: .init("clip"), asset: oldRecord.asset.id, ifCurrent: { true })
        let old = Task { try? await model.readHostThumbnail(oldAuthority) { await gate.wait(); return Data([1]) } }
        #expect(await eventually { gate.entered == 1 })
        try model.applyLocalRecords(.init(resetLibrary: true, upserts: [nextRecord]), token: model.actionToken)
        gate.release(); #expect(await old.value == nil)
        let nextAuthority = model.captureIO(key: .init("clip"), asset: nextRecord.asset.id, ifCurrent: { true })
        #expect(try await model.readHostThumbnail(nextAuthority) { Data([9]) } == Data([9]))
        #expect(model.records.map(\.asset.id) == [nextRecord.asset.id] && model.hostProgress.isEmpty)
    }

    @Test func lateSourceAcquisitionCannotBindAfterReplacement() async {
        let clock = HostIOSleep(), oldGate = HostIOGate(), old = HostIOService(), successor = HostIOService()
        let (root, model) = library(clock)
        defer { model.close(); oldGate.release(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        var oldReturned = false
        model.begin(acquiring: { await oldGate.wait(); oldReturned = true; return old })
        #expect(await eventually { oldGate.entered == 1 })
        #expect(model.acquiringSource && model.browsing)
        model.close()
        model.begin(acquiring: { successor })
        #expect(await eventually { model.binding == successor.browse.binding })
        oldGate.release()
        #expect(await eventually { oldReturned })
        #expect(model.binding == successor.browse.binding && !model.acquiringSource)
        #expect(old.opens == 0 && successor.opens == 1)
    }
    @Test func unknownSourceAcquisitionRetainsOfflineRowsAndReportsAbsence() async throws {
        let clock = HostIOSleep(), (root, model) = library(clock)
        defer { model.close(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let cached = HostIOCodec().capture(.init(id: .init("cached"), filename: "cached", representations: []),
            binding: HostIOBrowse().binding)
        try model.applyLocalRecords(.init(resetLibrary: false, upserts: [cached]), token: model.actionToken)
        model.begin(acquiring: { nil }, unavailableNote: "Source unavailable")
        #expect(await eventually { !model.acquiringSource })
        #expect(model.browsing && model.binding == nil && !model.canRefresh)
        #expect(model.note == "Source unavailable" && model.records.map(\.payload) == ["cached"] && model.catalog.assets.isEmpty)
    }
    /// A second download of the same clip (Share while the player's cache runs) joins the active
    /// writer: it neither retires it nor sends its own transfer, and it receives the cached file.
    @Test func duplicateDownloadJoinsTheActiveWriter() async throws {
        let clock = HostIOSleep(), gate = HostIOGate(), (root, model) = library(clock)
        defer { model.close(); gate.release(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let first = authority(model), duplicate = authority(model)
        let download = Task {
            try await model.cacheHostFile(first, purpose: .download, at: "files/a", expectedByteCount: 2) { sink in
                try await sink.write(Data([1])); await gate.wait(); try await sink.write(Data([2]))
                return .init(byteCount: 2)
            }
        }
        #expect(await eventually { gate.entered == 1 })
        var duplicateSent = false, duplicateEntered = false
        let joined = Task {
            duplicateEntered = true
            return try await model.cacheHostFile(duplicate, purpose: .download, at: "files/a") { _ in
                duplicateSent = true; return .init(byteCount: 1)
            }
        }
        #expect(await eventually { duplicateEntered })
        #expect(model.hostProgress[first.key] == 0.5)
        gate.release()
        let location = try #require(try await download.value)
        #expect(try await joined.value == location)
        #expect(!duplicateSent)
        #expect(try Data(contentsOf: location) == Data([1, 2]))
        #expect(model.records.isEmpty && model.catalog.assets.isEmpty)
    }
    /// Owner hardware report 2026-10-28: the player's cache was cancelled while its transport was
    /// still finishing a chunk; Share of that clip must cache it, not fail on the cancelled owner.
    @Test func downloadAfterACancelledDownloadOfTheSameClipCachesIt() async throws {
        let clock = HostIOSleep(), gate = HostIOGate(), (root, model) = library(clock)
        defer { model.close(); gate.release(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let player = authority(model), share = authority(model)
        let download = Task {
            try await model.cacheHostFile(player, purpose: .download, at: "files/a", expectedByteCount: 2) { sink in
                try await sink.write(Data([1])); await gate.wait(); try await sink.write(Data([2]))
                return .init(byteCount: 2)
            }
        }
        #expect(await eventually { gate.entered == 1 })
        download.cancel()
        var shareEntered = false
        let shared = Task {
            shareEntered = true
            return try await model.cacheHostFile(share, purpose: .download, at: "files/a", expectedByteCount: 2) { sink in
                try await sink.write(Data([3])); try await sink.write(Data([4]))
                return .init(byteCount: 2)
            }
        }
        #expect(await eventually { shareEntered })
        gate.release()
        await #expect(throws: (any Error).self) { try await download.value }
        let location = try #require(try await shared.value)
        #expect(try Data(contentsOf: location) == Data([3, 4]))
    }
    @Test func duplicateThumbnailDoesNotRetireActiveWriter() async throws {
        let clock = HostIOSleep(), gate = HostIOGate(), (root, model) = library(clock)
        defer { model.close(); gate.release(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let first = authority(model), duplicate = authority(model)
        let task = Task { try await model.ensureHostThumbnail(first, at: "thumb/a") { await gate.wait(); return Data([7]) } }
        #expect(await eventually { gate.entered == 1 })
        var duplicateSent = false
        try await model.ensureHostThumbnail(duplicate, at: "thumb/a") { duplicateSent = true; return Data([9]) }
        #expect(!duplicateSent)
        gate.release(); try await task.value
        #expect(try Data(contentsOf: root.appendingPathComponent("thumb/a")) == Data([7]))
        #expect(model.hostProgress.isEmpty)
    }
    @Test func clearDuringHostTransferCannotCommitOrEraseSuccessor() async throws {
        let clock = HostIOSleep(), gate = HostIOGate(), (root, model) = library(clock)
        defer { model.close(); gate.release(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let old = authority(model)
        let outgoing = Task { () -> Bool in
            do {
                _ = try await model.cacheHostFile(old, purpose: .download, at: "files/a") { sink in
                    try await sink.write(Data([1])); await gate.wait(); return .init(byteCount: 1)
                }
                return true
            } catch { return false }
        }
        #expect(await eventually { gate.entered == 1 })
        try await model.clearCache()
        #expect(!old.isCurrent && model.hostProgress.isEmpty)
        let fresh = authority(model)
        let location = try #require(try await model.cacheHostFile(fresh, purpose: .download, at: "files/a", expectedByteCount: 1) { sink in
            try await sink.write(Data([9])); return .init(byteCount: 1)
        })
        model.completeHostTransfer(fresh, role: .original)
        gate.release()
        #expect(await outgoing.value == false)
        #expect(try Data(contentsOf: location) == Data([9]))
        #expect(model.hostProgress[fresh.key] == 1)
    }
    @Test func libraryBeginRetiresUnindexedHostTransferWithoutInventingRows() async throws {
        let clock = HostIOSleep(), gate = HostIOGate(), (root, model) = library(clock)
        defer { model.close(); gate.release(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let old = authority(model)
        let outgoing = Task { () -> Bool in
            do {
                _ = try await model.cacheHostFile(old, purpose: .playback, at: "play/a") { sink in
                    try await sink.write(Data([1])); await gate.wait(); return .init(byteCount: 1)
                }; return true
            } catch { return false }
        }
        #expect(await eventually { gate.entered == 1 })
        model.begin()
        #expect(!old.isCurrent && model.hostProgress.isEmpty)
        gate.release(); #expect(await outgoing.value == false)
        #expect(model.records.isEmpty && model.catalog.assets.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("play/a").path))
    }
    @Test func headerLengthOverridesSourceHintForProgress() async throws {
        let clock = HostIOSleep(), (root, model) = library(clock)
        defer { model.close(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let capture = authority(model)
        var midpoint: Double?
        _ = try await model.cacheHostFile(capture, purpose: .playback, at: "play/a", expectedByteCount: 20) { sink in
            let progress = try #require(sink as? any MediaTransferProgressSink)
            try await progress.expectedByteCount(2)
            try await sink.write(Data([1])); midpoint = model.hostProgress[capture.key]
            try await sink.write(Data([2])); return .init(byteCount: 2, expectedByteCount: 2)
        }
        #expect(midpoint == 0.5 && model.hostProgress[capture.key] == 1)
    }
    @Test func unknownLengthDoesNotInventExpectedByteCount() async throws {
        let clock = HostIOSleep(), (root, model) = library(clock)
        defer { model.close(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let capture = authority(model)
        _ = try await model.cacheHostFile(capture, purpose: .playback, at: "play/a") { sink in
            try await sink.write(Data([7])); return .init(byteCount: 1)
        }
        #expect(model.hostProgress[capture.key] == 0 && model.catalog.assets.isEmpty)
    }
    @Test func oldCompletionTimerCannotEraseSuccessorProgress() async throws {
        let clock = HostIOSleep(), (root, model) = library(clock)
        defer { model.close(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let old = authority(model)
        model.completeHostTransfer(old, role: .original)
        #expect(await eventually { clock.gate.entered == 1 })
        #expect(clock.delays == [.milliseconds(450)])
        let fresh = authority(model)
        _ = try await model.cacheHostFile(fresh, purpose: .playback, at: "play/a", expectedByteCount: 2) { sink in
            try await sink.write(Data([7])); return .init(byteCount: 1)
        }
        clock.gate.release()
        for _ in 0..<100 { await Task.yield() }
        #expect(model.hostProgress[fresh.key] == 0.5)
    }
    @Test func synchronousProgressObserverCanReplaceBeforeDispatch() async throws {
        let clock = HostIOSleep(), (root, model) = library(clock)
        defer { model.close(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        let capture = authority(model)
        withObservationTracking { _ = model.hostProgress } onChange: {
            MainActor.assumeIsolated { model.close(); model.begin() }
        }
        var sent = false
        do {
            _ = try await model.cacheHostFile(capture, purpose: .download, at: "files/a") { _ in
                sent = true; return .init(byteCount: 1)
            }
            Issue.record("Outgoing host transfer survived source replacement")
        } catch {}
        #expect(!sent && model.browsing && model.hostProgress.isEmpty)
    }
    @Test func authorityFromAnotherLibraryCannotWriteSameRoot() async throws {
        let clock = HostIOSleep(), (root, first) = library(clock)
        let second = MonitorMediaLibraryModel(cache: first.cache, favorites: HostIOFavorites())
        defer { first.close(); second.close(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        var sent = false
        do {
            _ = try await second.cacheHostFile(authority(first), purpose: .download, at: "files/a") { _ in
                sent = true; return .init(byteCount: 1)
            }
            Issue.record("Another library accepted the outgoing authority")
        } catch {}
        #expect(!sent && second.hostProgress.isEmpty)
    }
    @Test func fallbackUsesFreshWriterAndRejectsLateAttemptSink() async throws {
        let clock = HostIOSleep(), (root, model) = library(clock)
        defer { model.close(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        var outgoingSink: (any MediaByteSink)?
        var accepted: [Int] = [], lateAccepted = false
        let plan = MediaTransferPlan(attempts: [
            { sink in outgoingSink = sink; try await sink.write(Data([1, 2])); throw HostIOAttemptError.failed },
            { sink in
                do { try await outgoingSink?.write(Data([3])); lateAccepted = true } catch {}
                try await sink.write(Data([9])); return .init(byteCount: 1)
            }
        ], retry: { _ in true }, accepted: { index, _ in accepted.append(index) })
        let location = try #require(try await model.cacheHostFile(authority(model), purpose: .playback, at: "play/a", plan: plan))
        #expect(try Data(contentsOf: location) == Data([9]))
        #expect(accepted == [1] && !lateAccepted)
        #expect(try FileManager.default.contentsOfDirectory(atPath: location.deletingLastPathComponent().path) == ["a"])
    }
    @Test func borrowedSinkReceivesOnlyAcceptedAttempt() async throws {
        let clock = HostIOSleep(), (root, model) = library(clock), sink = HostIOBorrowedSink()
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { model.close(); clock.gate.release(); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: stage) }
        var accepted: [Int] = []
        let plan = MediaTransferPlan(attempts: [
            { sink in try await sink.write(Data([1, 2])); throw HostIOAttemptError.failed },
            { sink in try await sink.write(Data([9])); return .init(byteCount: 1, expectedByteCount: 1) }
        ], retry: { _ in true }, accepted: { index, _ in accepted.append(index) })
        let receipt = try await model.transferHostFile(authority(model), into: sink, plan: plan, stagingRoot: stage)
        #expect(receipt == .init(byteCount: 1, expectedByteCount: 1))
        #expect(await sink.bytes == Data([9]))
        let remainingStagingFiles = try FileManager.default.contentsOfDirectory(atPath: stage.path)
        #expect(accepted == [1] && remainingStagingFiles.isEmpty)
        #expect(model.records.isEmpty && model.catalog.assets.isEmpty)
    }
    @Test func cancellationPreventsFallbackAndRemovesPartial() async throws {
        let clock = HostIOSleep(), gate = HostIOGate(), (root, model) = library(clock)
        defer { model.close(); gate.release(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        var fallbackSent = false, accepted = false
        let plan = MediaTransferPlan(attempts: [
            { sink in try await sink.write(Data([1])); await gate.wait(); throw HostIOAttemptError.failed },
            { sink in fallbackSent = true; try await sink.write(Data([9])); return .init(byteCount: 1) }
        ], retry: { _ in true }, accepted: { _, _ in accepted = true })
        let transfer = Task { () -> Bool in
            do { _ = try await model.cacheHostFile(authority(model), purpose: .playback, at: "play/a", plan: plan); return true }
            catch { return false }
        }
        #expect(await eventually { gate.entered == 1 })
        transfer.cancel(); gate.release()
        #expect(await transfer.value == false)
        #expect(!fallbackSent && !accepted && model.hostProgress.isEmpty)
        #expect((try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("play").path)).isEmpty)
    }
    @Test func sourcePredicateReentryCannotDispatchOutgoingAuthority() async throws {
        let clock = HostIOSleep(), (root, model) = library(clock)
        defer { model.close(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        var changed = false, sent = false
        let capture = model.captureIO(key: .init("a"), asset: nil) {
            if !changed { changed = true; model.close(); model.begin() }
            return true
        }
        do {
            _ = try await model.cacheHostFile(capture, purpose: .playback, at: "play/a") { _ in sent = true; return .init(byteCount: 1) }
            Issue.record("Outgoing authority dispatched after source predicate replacement")
        } catch {}
        #expect(changed && !sent && model.hostProgress.isEmpty)
    }
    @Test func retryPredicateReentryCannotDispatchFallback() async throws {
        let clock = HostIOSleep(), (root, model) = library(clock)
        defer { model.close(); clock.gate.release(); try? FileManager.default.removeItem(at: root) }
        var fallbackSent = false
        let plan = MediaTransferPlan(attempts: [
            { sink in try await sink.write(Data([1])); throw HostIOAttemptError.failed },
            { _ in fallbackSent = true; return .init(byteCount: 1) }
        ], retry: { _ in model.close(); model.begin(); return true })
        do {
            _ = try await model.cacheHostFile(authority(model), purpose: .playback, at: "play/a", plan: plan)
            Issue.record("Outgoing retry dispatched after source replacement")
        } catch {}
        #expect(!fallbackSent && model.hostProgress.isEmpty)
    }

}
