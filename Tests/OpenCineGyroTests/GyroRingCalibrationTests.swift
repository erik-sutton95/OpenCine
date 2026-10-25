import Foundation
import Testing

@testable import OpenCineGyro

/// A manual 30 Hz rig: one fixed mount rotation, matching phone and camera timestamps, and a
/// clock that only moves when a reading is fed.
private struct RingRig {
    static let mountAxis = GyroVector3(x: 0.3, y: -0.5, z: 0.8)
    static let mountDegrees = 37.0

    var calibration = GyroRingCalibration()
    var connected = true
    var recording: Bool? = false
    /// Extra turn about the phone's lens axis before the mount rotation, for a sideways mount.
    var rollDegrees = 0.0
    private(set) var tick = 0

    var timestamp: Double { Double(tick) / 30 }

    /// The phone's reading of a physical camera down through the mount rotation.
    func phoneDown(for cameraDown: GyroVector3) -> GyroVector3 {
        var turned = cameraDown
        if rollDegrees != 0 {
            turned = GyroTestRig.rotate(
                turned, axis: GyroVector3(x: 0, y: 0, z: 1), degrees: rollDegrees)
        }
        return GyroTestRig.rotate(turned, axis: Self.mountAxis, degrees: Self.mountDegrees)
    }

    mutating func start() {
        calibration.start(cameraConnected: connected, recording: recording)
    }

    /// Advances the clock by 1/30 s and feeds one reading. A nil camera down stands for a camera
    /// that reports no level.
    @discardableResult
    mutating func step(
        cameraDown: GyroVector3?, phoneDown: GyroVector3? = nil,
        cameraTimestampOffset: Double? = nil
    ) -> GyroRingEvent? {
        tick += 1
        let now = timestamp
        let phone: GyroVector3
        if let phoneDown {
            phone = phoneDown
        } else if let cameraDown {
            phone = self.phoneDown(for: cameraDown)
        } else {
            phone = GyroVector3(x: -1, y: 0, z: 0)
        }
        let cameraTime: Double?
        if cameraDown == nil {
            cameraTime = nil
        } else if let cameraTimestampOffset {
            cameraTime = now + cameraTimestampOffset
        } else {
            cameraTime = now
        }
        return calibration.observe(
            phoneDown: phone, phoneTimestamp: now, cameraDown: cameraDown,
            cameraTimestamp: cameraTime)
    }

    /// Holds one camera pose for the requested number of seconds, collecting non-nil events.
    @discardableResult
    mutating func hold(
        cameraDown: GyroVector3, seconds: Double, phoneDown: GyroVector3? = nil
    ) -> [GyroRingEvent] {
        var events: [GyroRingEvent] = []
        for _ in 0..<Int((seconds * 30).rounded()) {
            if let event = step(cameraDown: cameraDown, phoneDown: phoneDown) {
                events.append(event)
            }
        }
        return events
    }
}

@Suite("Ring calibration controller")
struct GyroRingCalibrationTests {
    private let level = GyroVector3(x: -1, y: 0, z: 0)
    private let left = GyroVector3(x: 0, y: 1, z: 0)
    private let backward = GyroVector3(x: 0, y: 0, z: 1)
    private let phoneVectors = [
        GyroVector3(x: 1, y: 0, z: 0), GyroVector3(x: 0.2, y: -0.7, z: 0.4),
        GyroVector3(x: -0.3, y: 0.1, z: 0.9),
    ]

    private var tiltUp: GyroVector3 {
        GyroTestRig.rotate(level, axis: left, degrees: 35)
    }
    private var tiltAndLean: GyroVector3 {
        GyroTestRig.rotate(
            GyroTestRig.rotate(level, axis: left, degrees: 30), axis: backward, degrees: 25)
    }

    @Test func threeHeldPosesCompleteWithAVerifiedCalibration() throws {
        var rig = RingRig()
        rig.start()
        var events: [GyroRingEvent] = []
        events += rig.hold(cameraDown: level, seconds: 3)
        events += rig.hold(cameraDown: tiltUp, seconds: 3)
        events += rig.hold(cameraDown: tiltAndLean, seconds: 3)

        #expect(events.count == 3)
        #expect(events.first == .stepCaptured(.level))
        #expect(events.dropFirst().first == .stepCaptured(.tiltUp))
        let calibration = try #require(completedCalibration(in: events))
        #expect(rig.calibration.completedSteps == 3)
        #expect(rig.calibration.phase == .complete(calibration))
        #expect(calibration.validationErrorDegrees < 1e-6)
        #expect(abs(calibration.separationDegrees - 35) < 1e-6)
        assertMapsMount(calibration, rig: rig)
    }

    @Test func holdFillsOverTwoSecondsAndResetsWhenLeavingTheZone() {
        var rig = RingRig()
        rig.start()
        #expect(rig.hold(cameraDown: level, seconds: 1).isEmpty)

        guard case let .posing(step, inZone, hold) = rig.calibration.phase else {
            Issue.record("Expected a posing level step, got \(rig.calibration.phase)")
            return
        }
        #expect(step == .level)
        #expect(inZone)
        let expected = (1 - 1.0 / 30) / GyroRingCalibration.holdSeconds
        #expect(abs(hold - expected) < 1e-9)

        _ = rig.step(cameraDown: GyroTestRig.rotate(level, axis: left, degrees: 40))
        #expect(rig.calibration.phase == .posing(step: .level, inZone: false, hold: 0))
        #expect(rig.calibration.completedSteps == 0)
    }

    @Test func notInZoneNeverCaptures() {
        var rig = RingRig()
        rig.start()
        let pitched = GyroTestRig.rotate(level, axis: left, degrees: 40)
        let events = rig.hold(cameraDown: pitched, seconds: 5)

        #expect(events.isEmpty)
        #expect(rig.calibration.phase == .posing(step: .level, inZone: false, hold: 0))
        #expect(rig.calibration.completedSteps == 0)
    }

    @Test func shakingInZoneShowsHoldSteadier() {
        var rig = RingRig()
        rig.start()
        let aligned = rig.phoneDown(for: level)
        for index in 0..<60 {
            let noise = index.isMultiple(of: 2) ? 5.0 : -5.0
            _ = rig.step(
                cameraDown: level,
                phoneDown: GyroTestRig.rotate(aligned, axis: backward, degrees: noise))
        }

        #expect(rig.calibration.phase == .blocked(step: .level, reason: .moving))
        #expect(rig.calibration.completedSteps == 0)
    }

    @Test func missingOrStaleCameraShowsWaitingForCamera() {
        var rig = RingRig()
        rig.start()

        _ = rig.step(cameraDown: nil)
        #expect(rig.calibration.phase == .blocked(step: .level, reason: .waitingForCamera))
        _ = rig.step(cameraDown: level, cameraTimestampOffset: -0.3)
        #expect(rig.calibration.phase == .blocked(step: .level, reason: .waitingForCamera))
        _ = rig.step(cameraDown: level, cameraTimestampOffset: 0.3)
        #expect(rig.calibration.phase == .blocked(step: .level, reason: .waitingForCamera))

        _ = rig.step(cameraDown: level)
        #expect(rig.calibration.phase == .posing(step: .level, inZone: true, hold: 0))
    }

    @Test func recordingAndDisconnectBlock() {
        var rig = RingRig()
        rig.connected = false
        rig.start()
        #expect(rig.calibration.phase == .blocked(step: .level, reason: .cameraDisconnected))
        #expect(rig.hold(cameraDown: level, seconds: 1).isEmpty)

        rig.connected = true
        rig.calibration.updateCamera(connected: true, recording: false)
        #expect(rig.calibration.phase == .blocked(step: .level, reason: .cameraDisconnected))
        _ = rig.step(cameraDown: level)
        #expect(rig.calibration.phase == .posing(step: .level, inZone: true, hold: 0))

        rig.calibration.updateCamera(connected: true, recording: true)
        #expect(rig.calibration.phase == .posing(step: .level, inZone: true, hold: 0))
        _ = rig.step(cameraDown: level)
        #expect(rig.calibration.phase == .blocked(step: .level, reason: .recording))

        rig.calibration.updateCamera(connected: false, recording: false)
        _ = rig.step(cameraDown: level)
        #expect(rig.calibration.phase == .blocked(step: .level, reason: .cameraDisconnected))

        var recordingRig = RingRig()
        recordingRig.recording = true
        recordingRig.start()
        #expect(
            recordingRig.calibration.phase == .blocked(step: .level, reason: .recording))
    }

    @Test func verificationFailureRestartsFromLevel() {
        var rig = RingRig()
        rig.start()
        #expect(rig.hold(cameraDown: level, seconds: 3) == [.stepCaptured(.level)])
        #expect(rig.hold(cameraDown: tiltUp, seconds: 3) == [.stepCaptured(.tiltUp)])
        #expect(rig.calibration.completedSteps == 2)

        let truePhone = rig.phoneDown(for: tiltAndLean)
        let turnedPhone = GyroTestRig.rotate(truePhone, axis: backward, degrees: 10)
        var events: [GyroRingEvent] = []
        for _ in 0..<90 {
            if let event = rig.step(cameraDown: tiltAndLean, phoneDown: turnedPhone) {
                events.append(event)
                break
            }
        }
        #expect(events == [.verificationFailed])
        #expect(rig.calibration.phase == .retrying)
        #expect(rig.calibration.completedSteps == 0)

        _ = rig.step(cameraDown: level)
        #expect(rig.calibration.phase == .posing(step: .level, inZone: true, hold: 0))
        #expect(rig.calibration.completedSteps == 0)
    }

    @Test func invalidationStopsAndStartRestarts() {
        var rig = RingRig()
        rig.start()
        #expect(rig.calibration.phase == .posing(step: .level, inZone: false, hold: 0))
        #expect(rig.hold(cameraDown: level, seconds: 3) == [.stepCaptured(.level)])
        #expect(rig.calibration.completedSteps == 1)

        rig.calibration.updateCamera(connected: false, recording: false)
        #expect(rig.calibration.phase == .invalidated(.connectionEnded))
        #expect(rig.calibration.completedSteps == 0)

        rig.start()
        #expect(rig.calibration.phase == .posing(step: .level, inZone: false, hold: 0))
        #expect(rig.hold(cameraDown: level, seconds: 3) == [.stepCaptured(.level)])

        rig.calibration.updateCamera(connected: true, recording: true)
        #expect(rig.calibration.phase == .invalidated(.recordingStarted))
        #expect(rig.calibration.completedSteps == 0)

        rig.calibration.invalidate(.cameraChanged)
        #expect(rig.calibration.phase == .invalidated(.cameraChanged))

        rig.start()
        #expect(rig.hold(cameraDown: level, seconds: 3) == [.stepCaptured(.level)])
        rig.calibration.cancel()
        #expect(rig.calibration.phase == .intro)
        #expect(rig.calibration.completedSteps == 0)
        #expect(rig.step(cameraDown: level) == nil)
    }

    @Test func ringCompletesWithPhoneMountedSideways() throws {
        var rig = RingRig()
        rig.rollDegrees = 90
        rig.start()
        var events: [GyroRingEvent] = []
        events += rig.hold(cameraDown: level, seconds: 3)
        events += rig.hold(cameraDown: tiltUp, seconds: 3)
        events += rig.hold(cameraDown: tiltAndLean, seconds: 3)

        let calibration = try #require(completedCalibration(in: events))
        #expect(rig.calibration.completedSteps == 3)
        #expect(calibration.validationErrorDegrees < 1e-6)
        assertMapsMount(calibration, rig: rig)
    }

    private func completedCalibration(in events: [GyroRingEvent]) -> GyroMountCalibration? {
        guard case .completed(let calibration)? = events.last else { return nil }
        return calibration
    }

    /// The calibration maps phone axes back into camera axes, so a round trip must recover the
    /// physical camera vector through the rig's mount rotation.
    private func assertMapsMount(_ calibration: GyroMountCalibration, rig: RingRig) {
        for vector in phoneVectors {
            let mapped = calibration.mapping(rig.phoneDown(for: vector))
            #expect(abs(mapped.x - vector.x) < 1e-9)
            #expect(abs(mapped.y - vector.y) < 1e-9)
            #expect(abs(mapped.z - vector.z) < 1e-9)
        }
    }
}
