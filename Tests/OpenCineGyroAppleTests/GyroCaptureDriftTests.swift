#if os(iOS)
import Foundation
import OpenCineCoreTestSupport
import OpenCineGyro
import Testing

@testable import OpenCineGyroApple

@MainActor @Suite("Gyro mount drift in the coordinator")
struct GyroCaptureDriftTests {
    /// About 5.7 degrees away from the level camera down: well past the drift threshold.
    private static let movedPhone = GyroVector3(x: -0.995037190209989, y: 0.0995037190209989, z: 0)

    /// An armed session on a camera with a saved calibration, logging and between takes.
    private func calibratedSession(
        _ fixture: GyroCoordinatorFixture
    ) async -> GyroCaptureCoordinator {
        await fixture.seedCalibration()
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        fixture.connect()
        coordinator.setupUseLastCalibration()
        let start = fixture.clock.time
        fixture.feed(from: start, through: start + 0.5)
        await coordinator.processPending()
        return coordinator
    }

    /// Records one take whose mount moved: REC, a steady mismatch, samples, then REC stop and
    /// the postroll.
    private func recordMovedTake(
        _ fixture: GyroCoordinatorFixture, _ coordinator: GyroCaptureCoordinator,
        phoneDown: GyroVector3 = movedPhone
    ) async {
        let start = fixture.clock.time
        fixture.record(true)
        fixture.hold(RingPoses.level, seconds: 1.5, phoneDown: phoneDown)
        fixture.feed(from: start + 0.01, through: fixture.clock.time)
        await coordinator.processPending()
    }

    private func stopTake(
        _ fixture: GyroCoordinatorFixture, _ coordinator: GyroCaptureCoordinator
    ) async {
        let stop = fixture.clock.time
        fixture.record(false)
        fixture.feed(from: stop + 0.01, through: stop + 2.5)
        await coordinator.processPending()
    }

    @Test func steadyMismatchMarksTheTakeAndTurnsThePillAmber() async throws {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = await calibratedSession(fixture)
        await recordMovedTake(fixture, coordinator)
        #expect(coordinator.driftHapticToken == 1)
        #expect(coordinator.pill.kind == .mountMoved)
        await stopTake(fixture, coordinator)
        let summary = try #require(coordinator.logs.first?.summary)
        let offset = try #require(summary.mountMovedOffset)
        #expect(offset > 0.9 && offset < 1.5)
        #expect(summary.descriptor.mountCalibration != nil)
        #expect(coordinator.pill.kind == .armed)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test func promptAppearsAfterRecStopsAndNotNowSilencesTheSession() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = await calibratedSession(fixture)
        await recordMovedTake(fixture, coordinator)
        #expect(!coordinator.driftPromptPresented)
        await stopTake(fixture, coordinator)
        #expect(coordinator.driftPromptPresented)
        coordinator.dismissDriftPrompt()
        #expect(!coordinator.driftPromptPresented)

        // A recalibration resets the detector; the next moved take is marked but not prompted.
        coordinator.beginCalibration()
        fixture.calibrate(coordinator)
        coordinator.finishCalibration()
        let resume = fixture.clock.time
        fixture.feed(from: resume, through: resume + 0.5)
        await coordinator.processPending()
        await recordMovedTake(fixture, coordinator)
        #expect(coordinator.driftHapticToken == 2)
        #expect(coordinator.pill.kind == .mountMoved)
        await stopTake(fixture, coordinator)
        #expect(!coordinator.driftPromptPresented)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test func notNowStillMarksLaterTakes() async throws {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = await calibratedSession(fixture)
        await recordMovedTake(fixture, coordinator)
        await stopTake(fixture, coordinator)
        #expect(coordinator.driftPromptPresented)
        coordinator.dismissDriftPrompt()
        for take in 2...3 {
            await recordMovedTake(fixture, coordinator)
            #expect(coordinator.driftHapticToken == take)
            #expect(coordinator.pill.kind == .mountMoved)
            await stopTake(fixture, coordinator)
            #expect(!coordinator.driftPromptPresented)
            let summary = try #require(coordinator.logs.first?.summary)
            #expect(summary.mountMovedOffset != nil)
        }
        #expect(coordinator.logs.count == 3)
        coordinator.enabled = false
        await coordinator.processPending()
        #expect(!coordinator.driftPromptPresented)
    }

    @Test func recordingIsNeverStopped() async throws {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = await calibratedSession(fixture)
        await recordMovedTake(fixture, coordinator)
        #expect(coordinator.driftHapticToken == 1)
        #expect(coordinator.motionRunning)
        #expect(coordinator.reportedRecording == true)
        #expect(coordinator.logs.first?.active == true)
        let more = fixture.clock.time
        fixture.feed(from: more + 0.01, through: more + 3)
        await coordinator.processPending()
        #expect(coordinator.logs.first?.active == true)
        await stopTake(fixture, coordinator)
        let summary = try #require(coordinator.logs.first?.summary)
        #expect(summary.termination == .normal)
        #expect(fixture.camera.writes.isEmpty)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test func uncalibratedSessionNeverDetectsDrift() async throws {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        await fixture.seedCalibration()
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        fixture.connect()
        coordinator.setupSkipCalibration()
        #expect(fixture.driver.motionConsumers.isEmpty)
        let start = fixture.clock.time
        fixture.feed(from: start, through: start + 0.5)
        await coordinator.processPending()
        await recordMovedTake(fixture, coordinator)
        #expect(coordinator.driftHapticToken == 0)
        #expect(coordinator.pill.kind == .recording)
        await stopTake(fixture, coordinator)
        let summary = try #require(coordinator.logs.first?.summary)
        #expect(summary.mountMovedOffset == nil)
        #expect(summary.descriptor.mountCalibration == nil)
        #expect(!coordinator.driftPromptPresented)
        coordinator.enabled = false
        await coordinator.processPending()
    }
}
#endif
