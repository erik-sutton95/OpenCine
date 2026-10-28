#if os(iOS)
import Foundation
import OpenCineCoreTestSupport
import OpenCineGyro
import Testing

@testable import OpenCineGyroApple

/// The three ring poses as camera downs; the test mount is the identity, so the phone reads
/// the same down.
enum RingPoses {
    static let level = GyroVector3(x: -1, y: 0, z: 0)
    /// Level tilted up 35 degrees about the left axis.
    static let tiltUp = GyroVector3(x: -0.8191520442889918, y: 0, z: 0.573576436351046)
    /// Level tilted up 30 degrees, then leaned 25 degrees about the backward axis.
    static let tiltAndLean = GyroVector3(
        x: -0.7848855672213958, y: -0.36599815077066683, z: 0.5)
    static let all = [level, tiltUp, tiltAndLean]
}

extension GyroCoordinatorFixture {
    /// Holds one still pose at 30 Hz: a fresh camera level, then the matching phone reading.
    func hold(_ down: GyroVector3, seconds: Double, phoneDown: GyroVector3? = nil) {
        for _ in 0..<Int((seconds * 30).rounded()) {
            clock.time += 1.0 / 30
            camera.send(.level(down, at: clock.time))
            driver.push(
                GyroDriftReading(
                    timestamp: clock.time, phoneDown: phoneDown ?? down, rotationRate: 0,
                    accelerationG: 1))
        }
    }

    /// Walks the whole ring on an open calibration screen.
    func calibrate(_ coordinator: GyroCaptureCoordinator) {
        coordinator.startRing()
        for pose in RingPoses.all { hold(pose, seconds: 3) }
    }

    /// Saves a calibration for the fake camera before a coordinator starts, through a ring run
    /// on a scratch coordinator sharing the same preferences.
    func seedCalibration() async {
        let seeding = coordinator()
        await seeding.waitUntilLoaded()
        connect()
        seeding.beginCalibration()
        calibrate(seeding)
        seeding.finishCalibration()
        camera.send(.disconnected)
        seeding.detachAdapter()
    }
}

@MainActor @Suite("Gyro ring calibration in the coordinator")
struct GyroCaptureCalibrationTests {
    @Test func threeHeldPosesSaveACalibrationForThisCamera() async throws {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        fixture.connect()
        #expect(coordinator.canCalibrate)
        #expect(!coordinator.hasSavedCalibration)
        coordinator.beginCalibration()
        #expect(coordinator.ring == .intro)
        coordinator.startRing()
        #expect(coordinator.ring == .posing(step: .level, inZone: false, hold: 0))
        fixture.hold(RingPoses.level, seconds: 3)
        #expect(coordinator.ringCompletedSteps == 1)
        #expect(coordinator.lastRingEvent == .stepCaptured(.level))
        #expect(coordinator.ringEventToken == 1)
        fixture.hold(RingPoses.tiltUp, seconds: 3)
        fixture.hold(RingPoses.tiltAndLean, seconds: 3)
        guard case .complete(let calibration) = coordinator.ring else {
            Issue.record("Expected a complete ring, got \(String(describing: coordinator.ring))")
            return
        }
        #expect(coordinator.lastRingEvent == .completed(calibration))
        #expect(coordinator.ringCompletedSteps == 3)
        #expect(coordinator.ringEventToken == 3)
        #expect(coordinator.hasSavedCalibration)
        #expect(fixture.preferences.calibration(for: "fake-1") == calibration)
        coordinator.finishCalibration()
        #expect(coordinator.ring == nil)
        #expect(fixture.driver.motionConsumers.isEmpty)
    }

    @Test func calibrationsAreKeptPerCamera() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        await fixture.seedCalibration()
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        fixture.connect()
        #expect(coordinator.hasSavedCalibration)
        fixture.camera.send(.disconnected)
        fixture.camera.identity = .init(id: "fake-2", name: "Second camera")
        fixture.connect()
        #expect(!coordinator.hasSavedCalibration)
        #expect(fixture.preferences.calibration(for: "fake-1") != nil)
        #expect(fixture.preferences.calibration(for: "fake-2") == nil)
    }

    @Test func recordingSourceChangeAndDisconnectInvalidate() async {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        fixture.connect()

        coordinator.beginCalibration()
        coordinator.startRing()
        fixture.hold(RingPoses.level, seconds: 3)
        #expect(coordinator.ringCompletedSteps == 1)
        fixture.record(true)
        #expect(coordinator.ring == .invalidated(.recordingStarted))
        #expect(fixture.driver.motionConsumers.isEmpty)
        fixture.record(false)

        coordinator.beginCalibration()
        coordinator.startRing()
        fixture.camera.send(.connected(.init(id: "fake-2", name: "Second camera")))
        #expect(coordinator.ring == .invalidated(.cameraChanged))

        coordinator.beginCalibration()
        coordinator.startRing()
        fixture.camera.send(.disconnected)
        #expect(coordinator.ring == .invalidated(.connectionEnded))
        #expect(!coordinator.hasSavedCalibration)

        fixture.connect()
        coordinator.beginCalibration()
        coordinator.appDidEnterBackground()
        #expect(coordinator.ring == .invalidated(.connectionEnded))
        #expect(fixture.driver.motionConsumers.isEmpty)
        coordinator.cancelCalibration()
        #expect(coordinator.ring == nil)
    }

    @Test func useLastCalibrationSkipsTheRing() async throws {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        await fixture.seedCalibration()
        let saved = try #require(fixture.preferences.calibration(for: "fake-1"))
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        fixture.connect()
        #expect(coordinator.setupSteps == [.calibration(hasSavedCalibration: true)])
        coordinator.setupUseLastCalibration()
        #expect(coordinator.setupSteps.isEmpty)
        #expect(coordinator.ring == nil)
        let start = fixture.clock.time
        fixture.feed(from: start, through: start + 2)
        fixture.record(true)
        await coordinator.processPending()
        #expect(coordinator.logs.first?.descriptor.mountCalibration == saved)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test func cancelDuringSetupArmsUncalibrated() async throws {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        fixture.connect()
        #expect(coordinator.setupSteps == [.calibration(hasSavedCalibration: false)])
        coordinator.beginCalibration()
        coordinator.startRing()
        fixture.hold(RingPoses.level, seconds: 3)
        coordinator.cancelCalibration()
        #expect(coordinator.ring == nil)
        #expect(coordinator.setupSteps.isEmpty)
        #expect(coordinator.isArmed)
        #expect(!coordinator.hasSavedCalibration)
        fixture.feed(from: fixture.clock.time, through: fixture.clock.time + 1)
        fixture.record(true)
        await coordinator.processPending()
        let take = try #require(coordinator.logs.first)
        #expect(take.active)
        #expect(take.descriptor.mountCalibration == nil)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test func doneAfterAnInvalidationInSetupLogsUncalibratedAndKeepsTheSavedCalibration()
        async throws
    {
        let fixture = GyroCoordinatorFixture()
        defer { fixture.cleanup() }
        await fixture.seedCalibration()
        let saved = try #require(fixture.preferences.calibration(for: "fake-1"))
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        fixture.connect()
        #expect(coordinator.setupSteps == [.calibration(hasSavedCalibration: true)])
        coordinator.beginCalibration()
        coordinator.startRing()
        fixture.hold(RingPoses.level, seconds: 3)
        fixture.record(true)
        #expect(coordinator.ring == .invalidated(.recordingStarted))
        coordinator.finishCalibration()
        #expect(coordinator.ring == nil)
        #expect(coordinator.setupSteps.isEmpty)
        #expect(coordinator.isArmed)
        #expect(coordinator.hasSavedCalibration)
        #expect(fixture.preferences.calibration(for: "fake-1") == saved)
        fixture.feed(from: fixture.clock.time, through: fixture.clock.time + 1)
        fixture.record(false)
        await coordinator.processPending()
        fixture.feed(from: fixture.clock.time, through: fixture.clock.time + 1)
        fixture.record(true)
        await coordinator.processPending()
        let take = try #require(coordinator.logs.first)
        #expect(take.active)
        #expect(take.descriptor.mountCalibration == nil, "Same as Cancel: the session logs uncalibrated")
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test func cameraWithoutLevelHidesCalibration() async {
        let fixture = GyroCoordinatorFixture(camera: FakeGyroCameraAdapter(providesLevel: false))
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        fixture.camera.connect(
            stabilization: .init(values: ["ibis": "ON"], lensHasVRSwitch: nil),
            at: fixture.clock.time)
        #expect(!coordinator.canCalibrate)
        #expect(coordinator.setupSteps == [.stabilization(lensHasVRSwitch: nil)])
        coordinator.beginCalibration()
        #expect(coordinator.ring == nil)
        #expect(coordinator.isArmed)
        coordinator.enabled = false
        await coordinator.processPending()
    }
}
#endif
