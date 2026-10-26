#if os(iOS)
import Foundation
import OpenCineGyro

/// Ring calibration: device-motion readings and the newest camera level feed
/// `GyroRingCalibration`; a completed ring is saved for the current camera.
@available(iOS 17, *)
extension GyroCaptureCoordinator {
    /// Adapter attached, camera with a level sensor, and connected.
    public var canCalibrate: Bool { providesLevel && camera != nil }

    /// Whether a calibration is saved for the current camera.
    public var hasSavedCalibration: Bool { savedCalibration != nil }

    /// Shows the calibration intro (`ring == .intro`).
    public func beginCalibration() {
        guard canCalibrate else { return }
        closeRing()
        guard startRingMotion() else { return }
        ring = .intro
    }

    /// "Get started": begins at the level pose unless a block already applies.
    public func startRing() {
        guard ring != nil, startRingMotion() else { return }
        ringCalibration.start(cameraConnected: camera != nil, recording: cameraRecording)
        lastRingEvent = nil
        publishRing()
    }

    /// The arming sheet's "Use last calibration": keeps the saved calibration, closes the step.
    public func setupUseLastCalibration() {
        guard hasSavedCalibration else { return }
        calibrationDeclined = false
        closeRing()
        dropSetupStep { if case .calibration = $0 { true } else { false } }
        refreshDrift(reset: true)
    }

    /// Closes calibration, keeping any previous calibration; in the arming sheet the session
    /// then logs uncalibrated (owner decision 2).
    public func cancelCalibration() {
        let inSetup = setupSteps.contains { if case .calibration = $0 { true } else { false } }
        closeRing()
        if inSetup { setupSkipCalibration() }
    }

    /// "Done" on the complete or the invalidated screen. Done after an invalidation in the
    /// arming sheet is a cancel: the session logs uncalibrated (owner decision 2).
    public func finishCalibration() {
        if case .invalidated = ring {
            cancelCalibration()
            return
        }
        closeRing()
        dropSetupStep { if case .calibration = $0 { true } else { false } }
        refreshDrift(reset: true)
    }

    // MARK: Ring wiring

    /// The current camera's saved calibration, read once per connection.
    func refreshSavedCalibration() {
        savedCalibration = camera.flatMap { preferences.calibration(for: $0.id) }
    }

    /// The calibration a REC observed now would freeze for its take.
    func recordingCalibration() -> GyroMountCalibration? {
        calibrationDeclined ? nil : savedCalibration
    }

    /// The session logs uncalibrated even when a calibration is saved.
    func declineCalibrationForSession() {
        calibrationDeclined = true
        refreshDrift(reset: true)
    }

    /// Whether an open calibration screen still has a ring to lose.
    var ringIsOpen: Bool {
        switch ring {
        case .intro, .posing, .blocked, .retrying: true
        case .invalidated, .complete, nil: false
        }
    }

    /// Discards an open ring with a reason the screen shows.
    func invalidateRing(_ reason: GyroCalibrationInvalidation) {
        guard ringIsOpen else { return }
        ringCalibration.invalidate(reason)
        publishRing()
    }

    /// Subscribes the ring to device motion once; false when the phone has none.
    private func startRingMotion() -> Bool {
        guard ringMotionToken == nil else { return true }
        do {
            ringMotionToken = try driver.startMotion { [weak self] reading in
                self?.observeRingReading(reading)
            }
            return true
        } catch {
            notice = .sensorUnavailable
            return false
        }
    }

    private func stopRingMotion() {
        if let token = ringMotionToken { driver.stopMotion(token) }
        ringMotionToken = nil
    }

    /// Keeps the ring's camera view current; it blocks or invalidates by its own rules.
    func updateRingCamera() {
        guard ring != nil else { return }
        ringCalibration.updateCamera(connected: camera != nil, recording: cameraRecording)
        publishRing()
    }

    func closeRing() {
        stopRingMotion()
        ringCalibration.cancel()
        ring = nil
        ringCompletedSteps = 0
        lastRingEvent = nil
    }

    private func observeRingReading(_ reading: GyroDriftReading) {
        guard ring != nil else { return }
        let event = ringCalibration.observe(
            phoneDown: reading.phoneDown, phoneTimestamp: reading.timestamp,
            cameraDown: cameraLevel?.down, cameraTimestamp: cameraLevel?.at)
        if let event {
            lastRingEvent = event
            ringEventToken += 1
            if case .completed(let calibration) = event, let camera {
                preferences.saveCalibration(calibration, for: camera.id)
                savedCalibration = calibration
                calibrationDeclined = false
                if cameraRecording != true { latestRecordingCalibration = calibration }
                evaluateEligibility()
            }
        }
        publishRing()
    }

    private func publishRing() {
        guard ring != nil else { return }
        // Device motion never runs behind an invalidated screen; "start again" resubscribes.
        if case .invalidated = ringCalibration.phase { stopRingMotion() }
        ring = ringCalibration.phase
        ringCompletedSteps = ringCalibration.completedSteps
    }
}
#endif
