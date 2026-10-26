#if os(iOS)
import Foundation
import OpenCineGyro

/// Session arming: the coordinator feeds `GyroArmingMachine` and applies its effects in order.
/// The machine owns every stabilization save and restore rule; nothing here decides policy.
@available(iOS 17, *)
extension GyroCaptureCoordinator {
    /// What the monitor pill shows.
    public var pill: GyroPillState {
        GyroPillState.resolve(
            enabled: enabled, failed: failed, armed: armed, motionRunning: motionRunning,
            hasFirstSample: hasFirstSample, activeTake: logs.contains { $0.active },
            cameraRecording: reportedRecording, gapWarning: hasGapWarning,
            mountMoved: mountMovedInTake, stabilizationWarning: stabilizationWarning)
    }

    /// Whether a capture session is armed for the current connection.
    public var isArmed: Bool { armed }

    /// "Turn off IBIS": writes the off values and closes the stabilization step.
    public func setupTurnOffStabilization() {
        apply(machine.chooseTurnOff())
        dropSetupStep { if case .stabilization = $0 { true } else { false } }
    }

    /// "Keep it on": arms with the warning mark and closes the stabilization step.
    public func setupKeepStabilization() {
        apply(machine.chooseKeepOn())
        dropSetupStep { if case .stabilization = $0 { true } else { false } }
    }

    /// Backs out of the calibration offer; the session logs uncalibrated (owner decision 2).
    public func setupSkipCalibration() {
        declineCalibrationForSession()
        dropSetupStep { if case .calibration = $0 { true } else { false } }
    }

    /// Ends the armed session before the host drops the link and waits for the stabilization
    /// restore, at most `restoreTimeout` (3 s). When the wait times out the disconnecting mark is
    /// cleared, so a link that never drops does not keep the session from arming again.
    public func prepareForDisconnect() async {
        disconnecting = true
        evaluateEligibility()
        if await !waitForCameraWrites(upTo: restoreTimeout) { disconnecting = false }
    }

    /// Waits for in-flight stabilization writes, at most `limit`; false when the limit won.
    func waitForCameraWrites(upTo limit: Duration) async -> Bool {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        Task { [weak self] in
            await self?.waitForCameraWrites()
            continuation.yield(true)
            continuation.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            continuation.yield(false)
            continuation.finish()
        }
        var finished = false
        for await value in stream {
            finished = value
            break
        }
        timer.cancel()
        return finished
    }

    /// Waits until no stabilization write is in flight, including writes a finish started and
    /// writes left over from an earlier connection.
    public func waitForCameraWrites() async {
        while let write = cameraWrites.values.first { await write.value }
    }

    // MARK: Machine wiring

    /// Feeds the arming machine the current observations and applies its effects.
    func evaluateEligibility() {
        if camera?.id != armingCameraID {
            armingCameraID = camera?.id
            writeGeneration += 1
        }
        apply(machine.update(armingInputs()))
    }

    func armingInputs() -> GyroArmingInputs {
        GyroArmingInputs(
            toggleOn: enabled, camera: camera, hostEligible: hostEligible && !disconnecting,
            videoMode: videoMode, recording: cameraRecording, stabilization: stabilization,
            settings: adapter?.stabilizationSettings ?? [],
            providesLevel: adapter?.providesLevel ?? false,
            hasSavedCalibration: hasSavedCalibration)
    }

    /// Applies machine effects in order, then mirrors the machine's armed and warning state.
    func apply(_ effects: [GyroArmingEffect]) {
        for effect in effects {
            switch effect {
            case .writeStabilization(let values, let purpose):
                startWrite(values, purpose: purpose)
            case .presentSetup(let steps):
                presentSetup(steps)
            case .persistPendingRestores(let restores):
                preferences.pendingRestores = restores
            case .sessionStarted:
                armed = true
                sessionDidStart()
                reconcile()
            case .sessionEnded:
                armed = false
                setupSteps = []
                stop(reason: endingReason ?? (enabled ? .disconnected : .disabled))
                sessionDidEnd()
            case .notice(let notice):
                switch notice {
                case .turnOffFailed: self.notice = .turnOffFailed
                case .restoreFailed: self.notice = .restoreFailed
                }
            }
        }
        armed = machine.isArmed
        stabilizationWarning = machine.stabilizationWarning
    }

    private func startWrite(_ values: [String: String], purpose: GyroWritePurpose) {
        guard let adapter else {
            apply(machine.writeFinished(purpose, succeeded: false))
            return
        }
        let token = UUID()
        let generation = writeGeneration
        cameraWrites[token] = Task { [weak self] in
            let succeeded = await adapter.writeStabilization(values)
            guard let self else { return }
            cameraWrites[token] = nil
            // A write from an earlier connection must not settle the current connection's write.
            guard generation == writeGeneration else { return }
            apply(machine.writeFinished(purpose, succeeded: succeeded))
        }
    }

    func dropSetupStep(where matches: (GyroArmingStep) -> Bool) {
        setupSteps.removeAll(where: matches)
    }

    // MARK: Session hooks

    /// A new sheet for a new session.
    func presentSetup(_ steps: [GyroArmingStep]) {
        if ring != nil, !ringIsOpen { closeRing() }
        setupSteps = steps
    }

    /// Per-session choices start fresh with every armed session.
    func sessionDidStart() {
        calibrationDeclined = false
        mountMovedInTake = false
        driftPromptSilenced = false
        refreshDrift(reset: true)
    }

    func sessionDidEnd() {
        stopDrift()
        driftPromptPresented = false
    }
}
#endif
