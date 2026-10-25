#if os(iOS)
import Foundation
import OpenCineGyro

/// Mount drift: while armed with a saved calibration and a camera level, a `GyroDriftDetector`
/// watches each recording take. A confirmed drift marks the take, never touches recording, and
/// offers recalibration after REC stops.
@available(iOS 17, *)
extension GyroCaptureCoordinator {
    /// Closes the prompt and opens calibration.
    public func recalibrateAfterDrift() {
        driftPromptPresented = false
        beginCalibration()
    }

    /// "Not now": no further prompts this armed session.
    public func dismissDriftPrompt() {
        driftPromptPresented = false
        driftPromptSilenced = true
    }

    // MARK: Drift wiring

    /// Starts, restarts or stops drift detection to match the session and its calibration.
    func refreshDrift(reset: Bool) {
        guard armed, providesLevel, let calibration = recordingCalibration() else {
            stopDrift()
            return
        }
        if reset || driftDetector == nil {
            var detector = GyroDriftDetector(calibration: calibration)
            if let cameraLevel { detector.observeCamera(down: cameraLevel.down, at: cameraLevel.at) }
            driftDetector = detector
        }
        guard driftMotionToken == nil else { return }
        driftMotionToken = try? driver.startMotion { [weak self] reading in
            self?.observeDriftReading(reading)
        }
    }

    func stopDrift() {
        if let token = driftMotionToken { driver.stopMotion(token) }
        driftMotionToken = nil
        driftDetector = nil
    }

    /// Tracks REC edges: a new take clears the mark; a stop after a marked take prompts once.
    func observeDriftRecording(from previous: Bool?, to recording: Bool?) {
        if recording == true, previous != true {
            mountMovedInTake = false
            // The detector latches; each take watches the mount afresh.
            refreshDrift(reset: true)
        } else if previous == true, recording != true, mountMovedInTake, !driftPromptSilenced {
            driftPromptPresented = true
        }
    }

    private func observeDriftReading(_ reading: GyroDriftReading) {
        guard cameraRecording == true, motionRunning, stopping == nil,
            driftDetector?.observePhone(reading) == true
        else { return }
        mountMovedInTake = true
        driftHapticToken += 1
        guard observations.count < GyroTakeSession.maximumBufferedSamples else {
            // The mark cannot reach the log in time: fail visibly, as a lost REC event does.
            fail(.recordingEventsLost)
            stop(reason: .bufferOverflow)
            return
        }
        observations.append(.mountMoved(at: reading.timestamp))
    }
}
#endif
