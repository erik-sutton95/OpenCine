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
        private(set) var sleepCount = 0
        private var sleepers: [(until: Duration, continuation: CheckedContinuation<Void, Never>)] = []

        func sleep(_ duration: Duration) async {
            sleepCount += 1
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
    @available(macOS 14, *)
    @Test func discoveryAfterTheDeadlineClearsTheHintAndDisappearanceArmsANewWait() async throws {
        let clock = ManualClock()
        let (model, fake) = model(clock)
        model.beginPairing()
        await clock.tick(.seconds(20))
        #expect(await eventually { model.scanLooksEmpty })
        fake.publish([NearbyCamera(id: "camera-1", name: "CAM-1", model: "Test Body", routes: [.cameraAccessPoint])])
        #expect(await eventually { !model.nearby.isEmpty })
        #expect(!model.scanLooksEmpty)
        fake.publish([])
        #expect(await eventually { model.nearby.isEmpty })
        #expect(await eventually { clock.sleepCount == 2 })
        clock.advance(by: .seconds(19))
        #expect(!model.scanLooksEmpty)
        clock.advance(by: .seconds(1))
        #expect(await eventually { model.scanLooksEmpty })
        model.endPairing()
    }

    @available(macOS 14, *)
    @Test func aCameraPresentAtTheOldDeadlineCanDisappearAndStartTheHintWait() async throws {
        let clock = ManualClock()
        let (model, fake) = model(clock)
        model.beginPairing()
        // Wait registration precedes discovery so the old deadline actually elapses.
        #expect(await eventually { clock.sleepCount == 1 })
        fake.publish([NearbyCamera(id: "camera-1", name: "CAM-1", model: "Test Body", routes: [.cameraAccessPoint])])
        #expect(await eventually { !model.nearby.isEmpty })
        clock.advance(by: .seconds(20))
        fake.publish([])
        #expect(await eventually { model.nearby.isEmpty })
        #expect(await eventually { clock.sleepCount == 2 })
        clock.advance(by: .seconds(20))
        #expect(await eventually { model.scanLooksEmpty })
        model.endPairing()
    }

    @available(macOS 14, *)
    @Test func unchangedEmptyPublicationsRetainTheDeadlineAndUnchangedSightingsKeepTheHintOff() async throws {
        let clock = ManualClock()
        let (model, fake) = model(clock)
        model.beginPairing()
        #expect(await eventually { clock.sleepCount == 1 })
        clock.advance(by: .seconds(19))
        fake.publish([])
        // Drain the stream's actor turn before advancing the original deadline.
        for _ in 0..<100 { await Task.yield() }
        clock.advance(by: .seconds(1))
        #expect(await eventually { model.scanLooksEmpty })
        #expect(clock.sleepCount == 1)
        let camera = NearbyCamera(id: "camera-1", name: "CAM-1", model: "Test Body", routes: [.cameraAccessPoint])
        fake.publish([camera])
        #expect(await eventually { !model.nearby.isEmpty })
        fake.publish([camera])
        for _ in 0..<100 { await Task.yield() }
        #expect(!model.scanLooksEmpty)
        #expect(clock.sleepCount == 1)
        model.endPairing()
    }

}
