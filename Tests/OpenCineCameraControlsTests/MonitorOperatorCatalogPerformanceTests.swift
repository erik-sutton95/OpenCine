#if os(iOS)
import Foundation
import Observation
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineMedia
import SwiftUI
import UIKit
import XCTest

/// SIMULATED 3200-record card (1500 RAW+JPEG pairs and 200 clips) in the actual shared catalog
/// screen. The host's facts closure stands in for the app: it counts how often the catalog asks
/// for a record and reads a host-observed transfer progress, as Z does. Budgets are call counts,
/// which do not depend on the simulator's speed. Field report 2026-10-25: Z iOS 304 Media stalled
/// on a large Nikon ZR card and was watchdog-killed.
@MainActor private final class PerfCatalogCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    let values: [MonitorMediaRecord<String>]
    init(_ values: [MonitorMediaRecord<String>]) { self.values = values }
    func decode(_ bytes: Data) throws -> [MonitorMediaRecord<String>] { values }
    func encode(_ records: [MonitorMediaRecord<String>]) throws -> Data { Data("catalog".utf8) }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<String> {
        throw MediaServiceError.unsupported
    }
}
@MainActor private final class PerfCatalogFavorites: MonitorMediaFavoritesStore {
    func favorites() -> Set<String> { [] }
    func saveFavorites(_ keys: Set<String>) {}
}
@MainActor @Observable private final class PerfCatalogInputs {
    var progress: [String: Double] = [:]
    @ObservationIgnored var factsCalls = 0
    @ObservationIgnored var cellCalls = 0
}
private struct PerfCatalogHost: View {
    let library: MonitorMediaLibraryModel<String>
    let inputs: PerfCatalogInputs
    var signalsCaching = false
    var body: some View {
        MonitorOperatorCatalogScreen(library: library, brand: "SIMULATED", sourceAvailable: true,
            operations: .init(), managesVisibility: false,
            facts: { record in
                inputs.factsCalls += 1
                return .init(resolution: nil, byteCount: 12_000, durationSeconds: nil, dateKey: nil,
                    colorLabel: nil, progress: inputs.progress[record.payload])
            },
            cell: { record, context in
                inputs.cellCalls += 1
                let progress = inputs.progress[record.payload]
                return .init(id: record.asset.id.rawValue, filename: record.asset.filename,
                    metadata: "", availability: .camera, progress: progress, favorite: record.favorite,
                    photo: record.asset.kind == .photo,
                    transferCaption: progress.map { "CACHING \(Int($0 * 100))%" })
            }, begin: {}, refresh: {}, close: {}, open: { _ in },
            cachingActive: signalsCaching ? { !inputs.progress.isEmpty } : nil) { _ in Color.gray }
    }
}

@MainActor final class MonitorOperatorCatalogPerformanceTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    private static let count = 3200

    private func library() throws -> MonitorMediaLibraryModel<String> {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencine-catalog-perf-" + UUID().uuidString)
        roots.append(root)
        let directory = MonitorMediaCacheDirectory(root: root)
        var names: [(String, MediaAssetKind)] = []
        for index in 0..<1500 {
            let stem = String(format: "DSC_%04d", index + 1)
            names.append((stem + ".NEF", .photo)); names.append((stem + ".JPG", .photo))
        }
        for index in 0..<200 { names.append((String(format: "DSC_%04d.MOV", 1501 + index), .video)) }
        let records = names.map { name, kind -> MonitorMediaRecord<String> in
            let id = "card1/" + name
            return .init(asset: .init(id: MediaAssetID(id), filename: name, kind: kind,
                representations: [.init(id: .init(id + "#original"), role: .original, byteCount: 12_000)]),
                payload: id, address: .init(thumbnail: "thumbs/" + name + ".jpg",
                    representations: [.init(id + "#original"): "files/" + name], favoriteKey: id),
                facts: .init(format: (name as NSString).pathExtension, dateKey: "20261025", orderKey: name,
                    presentationKind: kind))
        }
        try directory.write(Data("catalog".utf8), at: "index.json")
        let library = MonitorMediaLibraryModel(cache: .init(directory: directory, codec: PerfCatalogCodec(records),
            eligibility: .exactSize, catalogAddress: "index.json", preservedMetadata: ["index.json"]),
            favorites: PerfCatalogFavorites())
        library.visibility = .allRecords
        library.sort = .oldest
        return library
    }

    private func host(_ view: PerfCatalogHost) -> (UIWindow, UIHostingController<PerfCatalogHost>) {
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        return (window, host)
    }

    /// Lets SwiftUI apply pending observation changes, then lays out once more.
    private func render(_ host: UIViewController) async throws -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.view.layoutIfNeeded()
        return clock.now - start
    }

    private static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    func testLargeCardRendersAndUpdatesOnlyRealizedCells() async throws {
        let library = try library()
        let inputs = PerfCatalogInputs()
        let (window, host) = host(PerfCatalogHost(library: library, inputs: inputs))
        defer { window.isHidden = true; window.rootViewController = nil; library.close() }

        let first = try await render(host)
        _ = try await render(host)
        let initialCalls = inputs.cellCalls
        print("MEDIA-PERF catalog.initial.cellCalls: \(initialCalls) in \(String(format: "%.1f", Self.ms(first))) ms")
        XCTAssertGreaterThan(initialCalls, 0, "the catalog must render cells")

        // A transfer streaming one record: 30 host progress ticks.
        let target = "card1/DSC_0001.NEF"
        var tickCalls = 0
        var tickTime = Duration.zero
        for tick in 1...30 {
            inputs.factsCalls = 0; inputs.cellCalls = 0
            inputs.progress[target] = Double(tick) / 30
            tickTime += try await render(host)
            tickCalls = max(tickCalls, inputs.factsCalls + inputs.cellCalls)
        }
        print("MEDIA-PERF catalog.progressTick.maxCalls: \(tickCalls), avg \(String(format: "%.1f", Self.ms(tickTime) / 30)) ms")

        // Select-all, then toggling one selection.
        inputs.factsCalls = 0; inputs.cellCalls = 0
        library.select(Set(library.records.map(\.asset.id)))
        let selectTime = try await render(host)
        let selectAllCalls = inputs.factsCalls + inputs.cellCalls
        inputs.factsCalls = 0; inputs.cellCalls = 0
        var ids = library.selectedIDs
        ids.remove(library.records[5].asset.id)
        library.select(ids)
        let toggleTime = try await render(host)
        let toggleCalls = inputs.factsCalls + inputs.cellCalls
        print("MEDIA-PERF catalog.selectAll.calls: \(selectAllCalls) in \(String(format: "%.1f", Self.ms(selectTime))) ms")
        print("MEDIA-PERF catalog.toggleSelected.calls: \(toggleCalls) in \(String(format: "%.1f", Self.ms(toggleTime))) ms")

        // Realized cells only: a phone screen holds a few dozen; the eager map asked for all 3200.
        XCTAssertLessThan(initialCalls, 600, "initial render asked for \(initialCalls) cells of \(Self.count)")
        XCTAssertLessThan(tickCalls, 600, "one progress tick asked for \(tickCalls) records")
        // The tray reads only permissions of the selected records, never their whole items.
        XCTAssertLessThan(selectAllCalls, 600, "select all asked for \(selectAllCalls) records")
        XCTAssertLessThan(toggleCalls, 600, "a selection toggle asked for \(toggleCalls) records")
    }

    /// With the owner's caching signal, an idle catalog render does not ask every record's facts
    /// for the caching header (CodeRabbit on #271).
    func testIdleCachingHeaderDoesNotScanEveryRecord() async throws {
        let library = try library()
        let inputs = PerfCatalogInputs()
        let (window, host) = host(PerfCatalogHost(library: library, inputs: inputs, signalsCaching: true))
        defer { window.isHidden = true; window.rootViewController = nil; library.close() }
        _ = try await render(host)
        _ = try await render(host)
        inputs.factsCalls = 0
        library.sort = .newest
        _ = try await render(host)
        print("MEDIA-PERF catalog.idleResort.factsCalls: \(inputs.factsCalls)")
        XCTAssertLessThan(inputs.factsCalls, 600, "an idle re-sort asked \(inputs.factsCalls) facts")
    }
}
#endif
