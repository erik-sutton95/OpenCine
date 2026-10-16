import Foundation
import Observation
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineCore
import OpenCineMedia
import SwiftUI

// SIMULATED source. Only the shipped catalog and deletion owner render/schedule progress.
@main struct DeletionTestHost: App {
    @State private var fixture = DeletionHostFixture()
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                MonitorOperatorCatalogScreen(
                    library: fixture.library, brand: "SIMULATED deletion", sourceAvailable: false,
                    operations: .init(), managesVisibility: false,
                    deletionDetail: { progress in
                        fixture.companions
                            ? "\(progress.completed) of \(progress.total) files · incl. RAW + copies" : nil
                    },
                    facts: { _ in .init(resolution: nil, byteCount: nil, durationSeconds: nil,
                        dateKey: nil, colorLabel: nil) }, begin: {}, refresh: {},
                    close: { fixture.closed() }, open: { _ in }, thumbnail: { _ in Color.gray }).id(fixture.catalogRevision)
                HStack {
                    Text("CLOSES \(fixture.closes)").accessibilityIdentifier("SIMULATED.closes")
                    Button("Begin SIMULATED delete") { fixture.begin() }
                        .accessibilityIdentifier("SIMULATED.begin")
                }.frame(height: 54).frame(maxWidth: .infinity).background(Color.black)
            }.preferredColorScheme(.dark)
        }
    }
}

@MainActor @Observable private final class DeletionHostFixture {
    let library: MonitorMediaLibraryModel<String>
    let companions: Bool
    var closes = 0
    var catalogRevision = UUID()
    @ObservationIgnored private var held: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?
    private let total: Int
    private let completed: Int
    private let selected: Int

    init() {
        let env = ProcessInfo.processInfo.environment
        total = Int(env["SIMULATED_TOTAL"] ?? "1") ?? 1
        completed = Int(env["SIMULATED_COMPLETED"] ?? "0") ?? 0
        selected = Int(env["SIMULATED_SELECTED"] ?? "1") ?? 1
        companions = total > selected
        let directory = MonitorMediaCacheDirectory(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("SIMULATED-Z7-" + UUID().uuidString))
        library = MonitorMediaLibraryModel(
            cache: .init(directory: directory, codec: DeletionHostCodec(), eligibility: .exactSize,
                catalogAddress: "index.json", preservedMetadata: ["index.json"]),
            favorites: DeletionHostFavorites())
        library.begin()
    }
    func closed() { closes += 1; catalogRevision = UUID() }
    func begin() {
        guard task == nil else { return }
        let authority = library.captureDeletion(key: .init("SIMULATED-delete")) { true }
        let targets = (0..<total).map { MonitorMediaDeletionTarget(value: $0, locations: [$0]) }
        task = Task { [self] in
            _ = await library.deleteHostBatch(authority, targets: targets, selectedCount: selected,
                port: .init(remove: { location in
                    if location == self.completed {
                        await withCheckedContinuation { self.held = $0 }
                    }
                    return .removed
                }, commit: { _, _ in true }))
        }
    }
}
@MainActor private final class DeletionHostCodec: MonitorMediaCatalogCodec {
    typealias Payload = String
    func decode(_ bytes: Data) -> [MonitorMediaRecord<String>] { [] }
    func encode(_ records: [MonitorMediaRecord<String>]) -> Data { Data() }
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<String> {
        throw MediaServiceError.unsupported
    }
}
@MainActor private final class DeletionHostFavorites: MonitorMediaFavoritesStore {
    func favorites() -> Set<String> { [] }
    func saveFavorites(_ keys: Set<String>) {}
}
