#if os(iOS)
import Foundation
import Observation
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineMedia
import SwiftUI
import UIKit
import XCTest

/// SIMULATED records in a temporary cache, hosted in the actual shared catalog screen.
@MainActor private final class CatalogCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    let values: [MonitorMediaRecord<String>]
    init(_ values: [MonitorMediaRecord<String>]) { self.values = values }
    func decode(_ bytes: Data) throws -> [MonitorMediaRecord<String>] { values }
    func encode(_ records: [MonitorMediaRecord<String>]) throws -> Data { Data("catalog".utf8) }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<String> {
        throw MediaServiceError.unsupported
    }
}
@MainActor private final class CatalogFavorites: MonitorMediaFavoritesStore {
    func favorites() -> Set<String> { [] }
    func saveFavorites(_ keys: Set<String>) {}
}
@MainActor @Observable private final class CatalogHostInputs {
    var library: MonitorMediaLibraryModel<String>
    var sourceAvailable = true
    @ObservationIgnored var rendered: [String] = []
    init(library: MonitorMediaLibraryModel<String>) { self.library = library }
}
private struct CatalogHostView: View {
    let inputs: CatalogHostInputs
    var body: some View {
        MonitorOperatorCatalogScreen(library: inputs.library, brand: "SIMULATED",
            sourceAvailable: inputs.sourceAvailable, operations: .init(), managesVisibility: false,
            facts: { record in
                inputs.rendered.append(record.payload)
                return .init(resolution: nil, byteCount: nil, durationSeconds: nil, dateKey: nil, colorLabel: nil)
            }, begin: {}, refresh: {}, close: {}, open: { _ in }) { _ in Color.gray }
    }
}

@MainActor final class MonitorOperatorCatalogIdentityTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    private func library(_ prefix: String, count: Int) throws -> MonitorMediaLibraryModel<String> {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencine-catalog-" + UUID().uuidString)
        roots.append(root)
        let directory = MonitorMediaCacheDirectory(root: root)
        let records = (0..<count).map { index -> MonitorMediaRecord<String> in
            let id = String(format: "%@%02d", prefix, index)
            return .init(asset: .init(id: MediaAssetID(id), filename: id + ".mov", kind: .video,
                representations: [.init(id: .init(id + "-original"), role: .original, byteCount: 2)]),
                payload: id, address: .init(thumbnail: nil, representations: [.init(id + "-original"): id + ".mov"],
                    favoriteKey: id), facts: .init(format: "mov", dateKey: "20261012", orderKey: id))
        }
        try directory.write(Data("catalog".utf8), at: "index.json")
        let library = MonitorMediaLibraryModel(cache: .init(directory: directory, codec: CatalogCodec(records),
            eligibility: .exactSize, catalogAddress: "index.json", preservedMetadata: ["index.json"]),
            favorites: CatalogFavorites())
        library.visibility = .allRecords
        return library
    }

    private func host(_ inputs: CatalogHostInputs) -> (UIWindow, UIHostingController<CatalogHostView>) {
        let host = UIHostingController(rootView: CatalogHostView(inputs: inputs))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        return (window, host)
    }

    private func settle(_ host: UIViewController, until condition: () -> Bool) async throws -> Bool {
        for _ in 0..<60 {
            host.view.layoutIfNeeded()
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        host.view.layoutIfNeeded()
        return condition()
    }

    private static func scrollViews(_ view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    /// A2-02: a replaced library owner must drive the grid, not the first owner the screen saw.
    func testReplacedLibraryOwnerDrivesTheVisibleCatalog() async throws {
        let first = try library("A", count: 3), second = try library("B", count: 3)
        let inputs = CatalogHostInputs(library: first)
        let (window, host) = host(inputs)
        defer { window.isHidden = true; window.rootViewController = nil }
        let shown = try await settle(host) { inputs.rendered.contains("A00") }
        XCTAssertTrue(shown, "The first owner's records must render")
        first.close()
        inputs.library = second
        inputs.rendered.removeAll()
        let replaced = try await settle(host) { inputs.rendered.contains("B00") }
        inputs.rendered.removeAll()
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        XCTAssertTrue(replaced, "The replacement owner's records must render")
        XCTAssertFalse(inputs.rendered.contains { $0.hasPrefix("A") },
            "A retired owner must not keep driving the grid: \(inputs.rendered)")
        second.close()
    }

    /// A2-50: link availability is plain data; a flap keeps the operator's scroll position.
    func testSourceAvailabilityFlapKeepsTheScrollPosition() async throws {
        let owner = try library("S", count: 80)
        let inputs = CatalogHostInputs(library: owner)
        let (window, host) = host(inputs)
        defer { window.isHidden = true; window.rootViewController = nil; owner.close() }
        let ready = try await settle(host) {
            Self.scrollViews(host.view).contains { $0.contentSize.height > $0.bounds.height + 500 }
        }
        XCTAssertTrue(ready)
        let scroll = try XCTUnwrap(Self.scrollViews(host.view).first {
            $0.contentSize.height > $0.bounds.height + 500
        })
        scroll.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
        host.view.layoutIfNeeded()
        for available in [false, true] {
            inputs.sourceAvailable = available
            try await Task.sleep(for: .milliseconds(150))
            host.view.layoutIfNeeded()
            let current = try XCTUnwrap(Self.scrollViews(host.view).first {
                $0.window != nil && $0.contentSize.height > $0.bounds.height + 500
            })
            XCTAssertEqual(current.contentOffset.y, 400, accuracy: 1,
                "sourceAvailable=\(available) must not remount the catalog")
        }
    }
}
#endif
