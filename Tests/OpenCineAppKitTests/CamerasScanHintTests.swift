import Foundation
@testable import OpenCineAppKit
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

/// The still-looking hint is one Core rule (A2-65): `CamerasModel.scanLooksEmpty` turns on
/// after a 20-second scan without a camera, on the shared manual clock, never a per-app timer.
@MainActor
@Suite struct CamerasScanHintTests {
    /// A manual clock for the hint's wait: sleepers wake only on `advance(by:)`.
    /// `@unchecked Sendable`: the mutable state is confined to the main actor.
    private final class ManualClock: @unchecked Sendable {
        private(set) var now = Duration.zero
        private var sleepers: [(until: Duration, continuation: CheckedContinuation<Void, Never>)] = []

        func sleep(_ duration: Duration) async {
            await withCheckedContinuation { sleepers.append((now + duration, $0)) }
        }

        /// Waits until something sleeps on this clock, then advances it.
        func tick(_ duration: Duration) async {
            while sleepers.isEmpty { await Task.yield() }
            advance(by: duration)
        }

        func advance(by duration: Duration) {
            now += duration
            let due = sleepers.filter { $0.until <= now }
            sleepers.removeAll { $0.until <= now }
            for sleeper in due { sleeper.continuation.resume() }
        }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    @available(macOS 14, *)
    private func model(_ clock: ManualClock) -> (CamerasModel, FakeIntegration) {
        let fake = FakeIntegration(id: IntegrationID("test.scan-hint"))
        let model = CamerasModel(
            integrations: [AppIntegration(fake)],
            store: SavedCamerasStore(document: Defaults([:]).at("scan-hint")))
        model.waitForScanHint = { try await clock.sleep($0) }
        return (model, fake)
    }

    @available(macOS 14, *)
    @Test func aScanThatFindsNothingForTwentySecondsOffersTheStillLookingHint() async throws {
        let clock = ManualClock()
        let (model, _) = model(clock)
        model.beginPairing()
        #expect(model.scanning)
        #expect(!model.scanLooksEmpty)
        await clock.tick(.seconds(20))
        #expect(await eventually { model.scanLooksEmpty })
    }

    @available(macOS 14, *)
    @Test func aCameraInTheListKeepsTheHintOff() async throws {
        let clock = ManualClock()
        let (model, fake) = model(clock)
        model.beginPairing()
        fake.publish([NearbyCamera(id: "camera-1", name: "CAM-1", model: "Test Body", routes: [.cameraAccessPoint])])
        #expect(await eventually { !model.nearby.isEmpty })
        await clock.tick(.seconds(20))
        #expect(!model.scanLooksEmpty)
    }

    @available(macOS 14, *)
    @Test func leavingPairingClearsTheHint() async throws {
        let clock = ManualClock()
        let (model, _) = model(clock)
        model.beginPairing()
        await clock.tick(.seconds(20))
        #expect(await eventually { model.scanLooksEmpty })
        model.endPairing()
        #expect(!model.scanLooksEmpty)
    }
}
