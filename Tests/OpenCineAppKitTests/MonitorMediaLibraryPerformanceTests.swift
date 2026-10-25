import Foundation
import Observation
import OpenCineAppKit
import OpenCineCore
import OpenCineMedia
import Testing

/// SIMULATED camera card of realistic size: 1500 RAW+JPEG pairs (3000 photos) and 200 clips,
/// listed in 32-object pages like the Nikon cursor. Budgets are operation counts first (exact,
/// independent of the machine) and generous wall-clock ceilings second. Field report
/// 2026-10-25: Z iOS 304 on a Nikon ZR card stalled for long periods and was watchdog-killed.
enum MediaPerfCard {
    static let pairs = 1500
    static let clips = 200
    static let pageSize = 32
    static var count: Int { pairs * 2 + clips }

    static func assets() -> [MediaAsset] {
        var assets: [MediaAsset] = []
        assets.reserveCapacity(count)
        for index in 0..<pairs {
            let stem = String(format: "DSC_%04d", index + 1)
            for (suffix, bytes) in [("NEF", UInt64(48_000)), ("JPG", UInt64(12_000))] {
                assets.append(asset("\(stem).\(suffix)", kind: .photo, bytes: bytes, minute: index))
            }
        }
        for index in 0..<clips {
            let name = String(format: "DSC_%04d.MOV", pairs + index + 1)
            assets.append(asset(name, kind: .video, bytes: 900_000, minute: pairs + index))
        }
        return assets
    }

    static func asset(_ filename: String, kind: MediaAssetKind, bytes: UInt64, minute: Int) -> MediaAsset {
        .init(id: .init("card1/" + filename), volumeID: "slot1", filename: filename, kind: kind,
            capturedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(minute) * 60),
            representations: [.init(id: .init(filename + "#original"), role: .original, byteCount: bytes)],
            deletable: true)
    }

    static func pages(_ assets: [MediaAsset]) -> [MediaCatalogDelta] {
        stride(from: 0, to: assets.count, by: pageSize).map { start in
            let end = min(start + pageSize, assets.count)
            return .init(reset: start == 0, upserts: Array(assets[start..<end]), complete: end == assets.count)
        }
    }
}

@MainActor private final class PerfFavorites: MonitorMediaFavoritesStore {
    func favorites() -> Set<String> { [] }
    func saveFavorites(_ keys: Set<String>) {}
}

@MainActor private final class PerfCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    var encodedRecords = 0
    var saves = 0
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { [] }
    func encode(_ records: [MonitorMediaRecord<String>]) throws -> Data {
        saves += 1
        encodedRecords += records.count
        return Data("[]".utf8)
    }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) -> MonitorMediaRecord<String> {
        let representation = asset.representations[0].id
        return .init(asset: asset, payload: asset.filename,
            address: .init(thumbnail: "thumbs/" + asset.filename + ".jpg",
                representations: [representation: "files/" + asset.filename], favoriteKey: asset.filename),
            facts: .init(format: (asset.filename as NSString).pathExtension, dateKey: "20261025",
                orderKey: asset.filename, presentationKind: asset.kind))
    }
}

@MainActor private final class PerfCursor: MediaCatalogCursor {
    var pages: [MediaCatalogDelta]
    init(_ pages: [MediaCatalogDelta]) { self.pages = pages }
    func next() async -> MediaCatalogDelta? { pages.isEmpty ? nil : pages.removeFirst() }
    func close() {}
}

@MainActor private final class PerfThumbnails: CameraMediaThumbnailService {
    func thumbnail(_ asset: MediaAssetID) async throws -> Data { Data([0xFF, 0xD8, 0xFF, 0xD9]) }
}

/// Streams an original in many small chunks, like a camera transfer over Wi-Fi. Byte counts
/// are scaled down (a JPG is 12 kB here); only the number of progress ticks matters.
@MainActor private final class PerfTransfer: CameraMediaTransferService {
    let chunks: Int
    let chunk: Data
    init(chunks: Int, total: Int = 12_000) { self.chunks = chunks; chunk = Data(count: total / chunks) }
    func transfer(_ representation: MediaRepresentationID, into sink: any MediaByteSink) async throws
        -> MediaTransferReceipt
    {
        for _ in 0..<chunks { try await sink.write(chunk) }
        return .init(byteCount: UInt64(chunks * chunk.count), expectedByteCount: UInt64(chunks * chunk.count))
    }
}

@MainActor private final class PerfBrowse: CameraMediaBrowse {
    let binding = MediaBrowseBinding(session: .init(), epoch: .init(1))
    let thumbnailService = PerfThumbnails()
    var thumbnails: (any CameraMediaThumbnailService)? { thumbnailService }
    var transfers: (any CameraMediaTransferService)?
    var deletion: (any CameraMediaDeleteService)? { nil }
    var heldBySource: Bool? { nil }
    let assets: [MediaAsset]
    init(_ assets: [MediaAsset]) { self.assets = assets }
    func catalog() async -> any MediaCatalogCursor { PerfCursor(MediaPerfCard.pages(assets)) }
    func close() async {}
}

@MainActor private final class PerfService: CameraMediaService {
    let browse: PerfBrowse
    var sessionID: CameraSessionID { browse.binding.session }
    init(_ browse: PerfBrowse) { self.browse = browse }
    func openBrowse() async throws -> any CameraMediaBrowse { browse }
}

/// Counts what the shared gallery would pay: every background cache scan's record count.
@MainActor private final class ScanLedger {
    var scans = 0
    var scannedRecords = 0
}

@available(macOS 14, *)
@MainActor private struct PerfFixture {
    let root: URL
    let codec = PerfCodec()
    let ledger = ScanLedger()
    let service: PerfService
    let library: MonitorMediaLibraryModel<String>

    init(scanning: MonitorMediaCacheScanning = .background, transferChunks: Int = 0) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("opencine-media-perf-" + UUID().uuidString)
        let browse = PerfBrowse(MediaPerfCard.assets())
        if transferChunks > 0 { browse.transfers = PerfTransfer(chunks: transferChunks) }
        service = PerfService(browse)
        let ledger = ledger
        let cache = MonitorMediaCache(directory: .init(root: root), codec: codec,
            eligibility: .exactSize, catalogAddress: "index.json", preservedMetadata: ["index.json"])
        library = MonitorMediaLibraryModel(cache: cache, favorites: PerfFavorites(), service: service,
            cacheScanning: scanning, catalogBase: .freshListing, initialCatalog: .init(), initialRecords: [],
            readSnapshot: { plan in
                // Counted to completion even when the library supersedes this scan.
                let snapshot = try await Task.detached { try await plan.read() }.value
                ledger.scans += 1
                ledger.scannedRecords += snapshot.entries.count
                return snapshot
            }, sleep: { _ in })
        library.visibility = .allRecords
    }

    func list() async throws {
        library.begin()
        try await waitUntil { library.records.count == MediaPerfCard.count && !library.fetching }
    }

    func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("condition never held")
        throw CancellationError()
    }

    func close() {
        library.close()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private func measure(_ work: () throws -> Void) rethrows -> Duration {
    let clock = ContinuousClock()
    let start = clock.now
    try work()
    return clock.now - start
}

@MainActor private func measure(_ work: () async throws -> Void) async rethrows -> Duration {
    let clock = ContinuousClock()
    let start = clock.now
    try await work()
    return clock.now - start
}

private func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

private func report(_ name: String, _ value: String) {
    print("MEDIA-PERF \(name): \(value)")
}

/// Re-registers after each change, like a SwiftUI body that reads the same values again.
@available(macOS 14, *)
@MainActor private final class Invalidations {
    var count = 0
    private let read: @MainActor () -> Void
    init(_ read: @escaping @MainActor () -> Void) {
        self.read = read
        track()
    }
    private func track() {
        withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.count += 1
                self.track()
            }
        }
    }
}

@MainActor @Suite(.serialized) struct MonitorMediaLibraryPerformanceTests {
    /// Listing a 3200-object card must cost work proportional to each page, not to the whole
    /// library on every page: cache scans cover the new rows, and the catalog checkpoint is not
    /// re-encoded 100 times.
    @available(macOS 14, *)
    @Test func listingALargeCardScansAndPersistsInProportionToThePage() async throws {
        let fixture = PerfFixture()
        defer { fixture.close() }
        let elapsed = try await measure { try await fixture.list() }
        try await fixture.waitUntil { fixture.library.entries.count == MediaPerfCard.count }
        let pages = (MediaPerfCard.count + MediaPerfCard.pageSize - 1) / MediaPerfCard.pageSize
        report("listing.ms", String(format: "%.1f", milliseconds(elapsed)))
        report("listing.scannedRecords", "\(fixture.ledger.scannedRecords) in \(fixture.ledger.scans) scans")
        report("listing.encodedRecords", "\(fixture.codec.encodedRecords) in \(fixture.codec.saves) saves")
        // Each record is scanned about once (a page's own rows), not once per later page.
        #expect(fixture.ledger.scannedRecords <= MediaPerfCard.count * 2,
            "cache scans covered \(fixture.ledger.scannedRecords) records for \(MediaPerfCard.count) rows")
        // The whole catalog is encoded a bounded number of times, not once per page.
        #expect(fixture.codec.encodedRecords <= MediaPerfCard.count * 12,
            "checkpoints encoded \(fixture.codec.encodedRecords) records over \(pages) pages")
        // Wall time is reported, not asserted: a hosted runner runs other suites beside this one.
    }

    /// A transfer's progress ticks are not a catalog change: views that read the records or the
    /// displayed order must not be invalidated by them.
    @available(macOS 14, *)
    @Test func transferProgressDoesNotInvalidateRecordsOrDisplayedOrder() async throws {
        let fixture = PerfFixture(transferChunks: 200)
        defer { fixture.close() }
        try await fixture.list()
        try await fixture.waitUntil { fixture.library.entries.count == MediaPerfCard.count }
        let library = fixture.library
        let records = Invalidations { _ = library.records }
        let displayed = Invalidations { _ = library.displayedRecords.count }
        let selection = Invalidations { _ = library.selectedIDs }
        var progress = 0
        let progressObserver = Invalidations { _ = library.progress; progress += 1 }
        let target = library.records[1].asset.id
        let elapsed = try await measure { _ = try await library.cacheOriginal(target) }
        try await fixture.waitUntil { library.entries[target]?.originalURL != nil }
        for _ in 0..<20 { await Task.yield() }
        report("progress.ticks", "\(progressObserver.count)")
        report("progress.recordsInvalidations", "\(records.count)")
        report("progress.displayedInvalidations", "\(displayed.count)")
        report("progress.selectionInvalidations", "\(selection.count)")
        report("progress.transfer.ms", String(format: "%.1f", milliseconds(elapsed)))
        #expect(progressObserver.count > 0, "the progress observer must see the transfer")
        #expect(records.count == 0, "progress and cache ticks invalidated records \(records.count) times")
        #expect(displayed.count <= 2, "progress invalidated the displayed order \(displayed.count) times")
        #expect(selection.count == 0, "progress invalidated the selection \(selection.count) times")
        _ = progress
    }

    /// The displayed order is derived once per change, not filtered and sorted on every read.
    @available(macOS 14, *)
    @Test func repeatedDisplayedReadsReuseOneDerivation() async throws {
        let fixture = PerfFixture()
        defer { fixture.close() }
        try await fixture.list()
        fixture.library.sort = .name
        func storage(_ records: [MonitorMediaRecord<String>]) -> UnsafeRawPointer? {
            records.withUnsafeBufferPointer { UnsafeRawPointer($0.baseAddress) }
        }
        // The first list stays alive, so a fresh derivation can never reuse its storage address.
        let firstList = fixture.library.displayedRecords
        let first = storage(firstList)
        var reused = true
        let elapsed = measure {
            for _ in 0..<200 { reused = reused && storage(fixture.library.displayedRecords) == first }
        }
        report("displayed.200reads.ms", String(format: "%.1f", milliseconds(elapsed)))
        #expect(reused, "each read derived (filtered and sorted) the displayed records again")
        withExtendedLifetime(firstList) {}
        #expect(milliseconds(elapsed) < 1000, "200 reads took \(milliseconds(elapsed)) ms")
    }

    /// Selecting a whole card and resolving it for share/cache is linear, not quadratic.
    @available(macOS 14, *)
    @Test func selectAllAndResolveIsLinear() async throws {
        let fixture = PerfFixture()
        defer { fixture.close() }
        try await fixture.list()
        let gallery = MonitorMediaGalleryModel(library: fixture.library)
        var resolved = 0
        let elapsed = measure {
            fixture.library.selectAll()
            let snapshot = gallery.snapshot()
            resolved = snapshot.selected(fixture.library.selectedIDs).count
            _ = snapshot.selectableIDs.count
            for record in fixture.library.records { _ = fixture.library.record(record.asset.id) }
        }
        report("selectAll.resolve.ms", String(format: "%.1f", milliseconds(elapsed)))
        #expect(resolved == MediaPerfCard.count)
        #expect(milliseconds(elapsed) < 2000, "select all and resolve took \(milliseconds(elapsed)) ms")
    }

    /// One fetched thumbnail rescans that one record, not the whole card.
    @available(macOS 14, *)
    @Test func thumbnailCommitsRescanOnlyTheirRecord() async throws {
        let fixture = PerfFixture()
        defer { fixture.close() }
        try await fixture.list()
        try await fixture.waitUntil { fixture.library.entries.count == MediaPerfCard.count }
        let before = fixture.ledger.scannedRecords
        let ids = fixture.library.records.prefix(40).map(\.asset.id)
        let elapsed = try await measure {
            for id in ids { await fixture.library.ensureThumbnailAndWait(id) }
            try await fixture.waitUntil { ids.allSatisfy { fixture.library.entries[$0]?.thumbnailURL != nil } }
        }
        let scanned = fixture.ledger.scannedRecords - before
        report("thumbnails.40.scannedRecords", "\(scanned)")
        report("thumbnails.40.ms", String(format: "%.1f", milliseconds(elapsed)))
        #expect(scanned <= ids.count * 4, "40 thumbnails rescanned \(scanned) records")
    }
}
