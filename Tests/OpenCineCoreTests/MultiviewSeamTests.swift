import Foundation
import OpenCineCore
import Testing

/// The Multiview seams' shared behavior. Kotlin twin: `MultiviewSeamTest`.
@MainActor @Suite struct MultiviewSeamTests {
    @Test func aCommissionerThatCannotScanSaysSoWithoutCancelling() async {
        let commissioner = MenuOnlyCommissioner()
        #expect(!commissioner.scansNetworks)
        await #expect(throws: StationScanUnsupported.self) {
            try await commissioner.scanNetworks(
                through: "camera", beforeStationChange: {}, onRestored: { _ in }, onFound: { _ in })
        }
    }
}

/// A commissioner with no network scan of its own.
@MainActor
private final class MenuOnlyCommissioner: StationCommissioner {
    typealias Camera = String

    func record(_ camera: String) -> StationCameraRecord {
        StationCameraRecord(id: UUID(), name: camera, modelId: nil)
    }

    func connect(
        _ camera: String, progress: @escaping @MainActor (String) -> Void
    ) async throws -> any StationCommission {
        throw StationScanUnsupported()
    }

    func closeCommissions() {}

    func restoreAccessPoint(_ record: StationCameraRecord) async -> Bool { false }
}
