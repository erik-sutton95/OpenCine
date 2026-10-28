#if os(iOS)
import Foundation
import Observation
import OpenCineGyro
import UIKit

/// Owns a foreground phone-motion session independently of monitor overlays and the log browser.
/// A host feeds camera state through a `GyroCameraAdapter`; the coordinator never commands
/// recording.
@available(iOS 17, *) @MainActor @Observable
public final class GyroCaptureCoordinator: GyroCameraSink {
    /// The saved Gyro toggle: arm whenever possible.
    public var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            preferences.enabled = enabled
            if enabled {
                if loaded { latestRecordingCalibration = recordingCalibration() }
                failed = false
            }
            evaluateEligibility()
        }
    }
    /// Takes newest first, as the store reports them.
    public private(set) var logs: [GyroLogEntry] = []
    /// The latest problem to show; the shared UI resolves its wording.
    public internal(set) var notice: GyroNotice? {
        didSet { if notice != nil { noticeToken += 1 } }
    }
    /// Bumped on every notice set, so a repeated identical notice still restarts the banner
    /// timer and its announcement.
    public private(set) var noticeToken = 0
    /// Whether raw gyro samples are being collected.
    public private(set) var motionRunning = false
    /// Whether the logs browser is shown.
    public var logsPresented = false
    /// Whether capture failed; cleared when the toggle is turned on again.
    public private(set) var failed = false
    /// Whether an open take contains a sensor gap.
    public private(set) var hasGapWarning = false
    /// Whether the running session has accepted a sensor sample.
    public private(set) var hasFirstSample = false
    /// The recording state the take session last observed.
    public private(set) var reportedRecording: Bool?
    /// The active camera body, or nil when not connected.
    public private(set) var camera: GyroCameraIdentity?
    /// Arming sheet steps; non-empty shows the sheet and the first is the current step.
    public internal(set) var setupSteps: [GyroArmingStep] = []
    /// Whether the logs tip was dismissed.
    private var tipDismissed: Bool
    /// Mirrors the arming machine: a session is armed for the current connection.
    var armed = false
    /// Mirrors the arming machine: the operator kept stabilization on.
    var stabilizationWarning = false
    /// The open take saw a confirmed mount movement.
    var mountMovedInTake = false
    /// The calibration screen's phase; nil when calibration is not presented.
    public internal(set) var ring: GyroRingPhase?
    /// Accepted ring poses, 0 to 3.
    public internal(set) var ringCompletedSteps = 0
    /// The latest ring transition, for the checkmark, haptic and announcement.
    public internal(set) var lastRingEvent: GyroRingEvent?
    /// Bumped on every ring event, so a repeated identical event is still observable.
    public internal(set) var ringEventToken = 0
    /// Whether the post-take "mount moved" prompt is shown.
    public internal(set) var driftPromptPresented = false
    /// Bumped once per confirmed drift; the view plays one light haptic per change.
    public internal(set) var driftHapticToken = 0
    /// Whether the attached adapter's camera has a level sensor.
    var providesLevel = false
    /// The current camera's saved calibration.
    var savedCalibration: GyroMountCalibration?

    @ObservationIgnored let host: GyroHostConfiguration
    @ObservationIgnored let preferences: GyroPreferences
    @ObservationIgnored let driver: any GyroMotionDriving
    @ObservationIgnored let store: any GyroLogStoring
    @ObservationIgnored let now: () -> Double
    @ObservationIgnored let automaticProcessing: Bool
    @ObservationIgnored var adapter: (any GyroCameraAdapter)?
    @ObservationIgnored var hostEligible = false
    @ObservationIgnored var videoMode: Bool?
    @ObservationIgnored var cameraRecording: Bool?
    @ObservationIgnored var stabilization: GyroStabilizationState?
    @ObservationIgnored var machine: GyroArmingMachine
    /// Stabilization writes in flight, keyed by a per-write token.
    @ObservationIgnored var cameraWrites: [UUID: Task<Void, Never>] = [:]
    /// Bumped whenever the camera id changes, the arming machine's connection rule; a write
    /// that finishes under an older generation never reaches the machine.
    @ObservationIgnored var writeGeneration = 0
    @ObservationIgnored var armingCameraID: String?
    @ObservationIgnored var disconnecting = false
    @ObservationIgnored var calibrationDeclined = false
    @ObservationIgnored var ringCalibration = GyroRingCalibration()
    @ObservationIgnored var ringMotionToken: UUID?
    @ObservationIgnored var cameraLevel: (down: GyroVector3, at: Double)?
    @ObservationIgnored var driftDetector: GyroDriftDetector?
    @ObservationIgnored var driftMotionToken: UUID?
    @ObservationIgnored var driftPromptSilenced = false
    /// The longest `prepareForDisconnect` waits for the restore.
    @ObservationIgnored var restoreTimeout: Duration = .seconds(3)
    @ObservationIgnored var session: GyroTakeSession
    @ObservationIgnored var buffer = GyroSampleBuffer()
    @ObservationIgnored var worker: Task<Void, Never>?
    @ObservationIgnored var loading: Task<Void, Never>?
    @ObservationIgnored var observations: [PendingObservation] = []
    @ObservationIgnored var stopping: GyroLogTermination?
    @ObservationIgnored var latestRecordingCalibration: GyroMountCalibration?
    @ObservationIgnored var loaded = false
    @ObservationIgnored var processing = false
    @ObservationIgnored var endingReason: GyroLogTermination?
    @ObservationIgnored var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// A backgrounded stop still has its final save to write.
    @ObservationIgnored var backgroundSavePending = false
    /// Waits, at most `restoreTimeout`, for the stabilization restore a backgrounding started.
    @ObservationIgnored var backgroundRestore: Task<Void, Never>?
    /// Starts a UIKit background task; replaced in tests that run without an application.
    @ObservationIgnored var beginBackgroundTask:
        @MainActor (_ expiration: @escaping @MainActor @Sendable () -> Void)
            -> UIBackgroundTaskIdentifier = { expiration in
                UIApplication.shared.beginBackgroundTask(
                    withName: "Save gyro log", expirationHandler: expiration)
            }
    /// Ends a UIKit background task; replaced in tests that run without an application.
    @ObservationIgnored var endBackgroundTaskHandler: @MainActor (UIBackgroundTaskIdentifier) -> Void =
        { UIApplication.shared.endBackgroundTask($0) }

    /// One camera observation queued for the take session, in arrival order.
    enum PendingObservation {
        case recording(Bool, at: Double, date: Date, label: String, calibration: GyroMountCalibration?)
        case mountMoved(at: Double)

        var timestamp: Double {
            switch self {
            case .recording(_, let at, _, _, _): at
            case .mountMoved(let at): at
            }
        }
    }

    /// Creates the coordinator for one host. Every collaborator is injectable for tests.
    public init(
        host: GyroHostConfiguration, driver: (any GyroMotionDriving)? = nil,
        store: (any GyroLogStoring)? = nil, keyValueStore: (any GyroKeyValueStore)? = nil,
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        automaticProcessing: Bool = true
    ) {
        self.host = host
        let preferences = GyroPreferences(
            store: keyValueStore ?? UserDefaultsGyroStore(defaults: .standard),
            keys: host.preferenceKeys, legacy: host.legacyKeys)
        self.preferences = preferences
        self.driver = driver ?? PhoneMotionDriver.shared
        let store = store ?? GyroLogStore(directory: host.logDirectory)
        self.store = store
        self.now = now
        self.automaticProcessing = automaticProcessing
        session = GyroTakeSession(appName: host.appName)
        machine = GyroArmingMachine(pendingRestores: preferences.pendingRestores)
        enabled = preferences.enabled
        tipDismissed = preferences.tipDismissed
        loading = Task { [weak self] in
            let result: Result<GyroLogRecoveryResult, any Error>
            do { result = .success(try await store.load()) } catch { result = .failure(error) }
            guard let self else { return }
            switch result {
            case .success(let recovered):
                logs = recovered.entries
                if recovered.warning != nil { notice = .recoveryIncomplete }
            case .failure:
                failed = true
                notice = .openFailed
            }
            loaded = true
            reconcile()
        }
    }

    /// Whether the dismissible logs tip is shown.
    public var tipVisible: Bool { !tipDismissed }

    /// Hides the logs tip for good.
    public func dismissTip() {
        tipDismissed = true
        preferences.tipDismissed = true
    }

    /// Starts receiving camera observations from an adapter, replacing any previous one.
    public func attach(_ adapter: any GyroCameraAdapter) {
        if let current = self.adapter, current !== adapter { detachAdapter() }
        self.adapter = adapter
        providesLevel = adapter.providesLevel
        adapter.attach(self)
    }

    /// Stops receiving camera observations and treats the camera as disconnected.
    public func detachAdapter() {
        guard let adapter else { return }
        adapter.detach()
        receive(.disconnected)
        self.adapter = nil
        providesLevel = false
    }

    /// Monitor showing, app in front, and no multicam or relay.
    public func setHostEligible(_ eligible: Bool) {
        guard hostEligible != eligible else { return }
        hostEligible = eligible
        evaluateEligibility()
    }

    /// Ends capture as backgrounded; the save and the stabilization restore (at most
    /// `restoreTimeout`) finish inside a UIKit background task.
    public func appDidEnterBackground() {
        invalidateRing(.connectionEnded)
        endingReason = .backgrounded
        hostEligible = false
        evaluateEligibility()
        endingReason = nil
        holdBackgroundTaskForRestore()
    }

    /// Handles one camera observation in adapter order.
    public func receive(_ event: GyroCameraEvent) {
        switch event {
        case .connected(let identity):
            let changed = camera?.id != identity.id
            if changed, camera != nil { invalidateRing(.cameraChanged) }
            camera = identity
            if changed {
                cameraLevel = nil
                refreshSavedCalibration()
            }
            disconnecting = false
        case .disconnected:
            invalidateRing(.connectionEnded)
            camera = nil
            savedCalibration = nil
            cameraLevel = nil
            driftDetector?.observeCamera(down: nil, at: now())
            videoMode = nil
            stabilization = nil
            disconnecting = false
            observeCameraRecording(nil)
        case .recording(let recording, _):
            let previous = cameraRecording
            observeCameraRecording(recording)
            observeDriftRecording(from: previous, to: recording)
        case .level(let down, let time):
            cameraLevel = down.map { ($0, time) }
            driftDetector?.observeCamera(down: down, at: time)
        case .stabilization(let state):
            stabilization = state
        case .videoMode(let mode):
            videoMode = mode
        }
        evaluateEligibility()
        updateRingCamera()
        if case .recording(let recording?, let time) = event { observeRecording(recording, at: time) }
    }

    /// Waits for the saved logs to load.
    public func waitUntilLoaded() async { await loading?.value }

    /// Copies finished logs for sharing, in order; an empty result means sharing was refused.
    public func share(_ ids: [UUID]) async -> [URL] {
        do { return try await store.share(ids) } catch {
            notice = .shareFailed
            return []
        }
    }

    /// Deletes one finished log.
    public func delete(_ id: UUID) async {
        do { logs = try await store.delete(id) } catch {
            notice = .deleteFailed
        }
    }

    /// Clears the visible notice.
    public func clearNotice() { notice = nil }

    private func observeCameraRecording(_ recording: Bool?) {
        if cameraRecording != recording {
            latestRecordingCalibration = recordingCalibration()
        }
        cameraRecording = recording
    }

    // MARK: Logging pipeline

    /// Queues a recording change for the take session when capture is running.
    func observeRecording(_ recording: Bool, at time: Double) {
        guard motionRunning, stopping == nil, reportedRecording != recording else { return }
        guard observations.count < GyroTakeSession.maximumBufferedSamples else {
            fail(.recordingEventsLost)
            stop(reason: .bufferOverflow)
            return
        }
        reportedRecording = recording
        observations.append(
            .recording(
                recording, at: time, date: Date(), label: camera?.name ?? "",
                calibration: latestRecordingCalibration))
    }

    /// Ends motion collection; the next `processPending` finalizes open takes with the reason.
    func stop(reason: GyroLogTermination) {
        guard motionRunning, stopping == nil else { return }
        driver.stopGyro()
        stopping = reason
        if reason == .backgrounded {
            backgroundSavePending = true
            beginBackgroundTaskIfNeeded()
        }
    }

    func fail(_ reason: GyroNotice) {
        failed = true
        notice = reason
    }

    func reconcile() {
        guard armed, loaded, !failed, worker == nil, !motionRunning else { return }
        session = GyroTakeSession(appName: host.appName)
        buffer = GyroSampleBuffer()
        observations.removeAll()
        reportedRecording = nil
        stopping = nil
        hasGapWarning = false
        hasFirstSample = false
        _ = session.poll(at: now())
        do { try driver.startGyro(into: buffer) } catch {
            fail(.sensorUnavailable)
            return
        }
        motionRunning = true
        if let cameraRecording { observeRecording(cameraRecording, at: now()) }
        guard automaticProcessing else { return }
        worker = Task { [weak self] in
            while let self, self.motionRunning {
                await self.processPending()
                if self.motionRunning { try? await Task.sleep(for: .milliseconds(100)) }
            }
            guard let self else { return }
            self.worker = nil
            self.reconcile()
        }
    }

    /// Drains samples before state changes or finalization so pending callback batches are
    /// retained.
    public func processPending() async {
        guard motionRunning, !processing else { return }
        processing = true
        defer {
            processing = false
            if !motionRunning {
                backgroundSavePending = false
                endBackgroundTaskIfIdle()
                if !automaticProcessing { reconcile() }
            }
        }
        let time = now()
        let batch = buffer.drain()
        var updates: [GyroLogUpdate] = []
        var remaining = batch.samples[...]
        // Interleave camera observations with their sensor-time prefixes. Ingesting a whole
        // delayed batch first would prune pre-roll that belongs to an earlier REC observation.
        for observation in observations {
            let boundary =
                remaining.firstIndex { $0.timestamp > observation.timestamp } ?? remaining.endIndex
            updates += session.ingest(Array(remaining[..<boundary]))
            switch observation {
            case .recording(let recording, let at, let date, let label, let calibration):
                updates += session.observeRecording(
                    recording, at: at, date: date, cameraLabel: label,
                    mountCalibration: calibration)
            case .mountMoved(let at):
                updates += session.observeMountMoved(at: at)
            }
            remaining = remaining[boundary...]
        }
        updates += session.ingest(Array(remaining))
        observations.removeAll(keepingCapacity: true)
        if let reason = stopping ?? batch.failure {
            updates += session.finish(reason: reason)
            if let failure = batch.failure, stopping == nil {
                fail(failure == .bufferOverflow ? .samplesLost : .sensorStalled)
            }
            stopping = nil
        } else {
            updates += session.poll(at: time)
        }
        // A stalled armed session has no open file, so the core can finish without an update.
        if session.isFinished {
            motionRunning = false
            driver.stopGyro()
            if session.termination == .sensorStalled { fail(.sensorStalled) }
        }
        hasGapWarning = session.hasGapWarning
        hasFirstSample = session.latestSampleTimestamp != nil
        do { logs = try await store.apply(updates, at: time) } catch {
            motionRunning = false
            driver.stopGyro()
            fail(.saveFailed)
            // The file may contain only part of this batch. Recover bytes actually written,
            // never publish the session's in-memory sample count as a successful disk write.
            let recovered = await store.abort()
            logs = recovered.entries
        }
    }

    // MARK: Background task

    /// Keeps the background task open while a stabilization restore is in flight, so leaving the
    /// app does not suspend it before the camera is put back; bounded by `restoreTimeout`.
    private func holdBackgroundTaskForRestore() {
        guard !cameraWrites.isEmpty, backgroundRestore == nil else { return }
        beginBackgroundTaskIfNeeded()
        let limit = restoreTimeout
        backgroundRestore = Task { [weak self] in
            _ = await self?.waitForCameraWrites(upTo: limit)
            guard let self else { return }
            backgroundRestore = nil
            endBackgroundTaskIfIdle()
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = beginBackgroundTask { [weak self] in self?.endBackgroundTask() }
    }

    /// Ends the background task once the save and the restore are both done.
    private func endBackgroundTaskIfIdle() {
        guard !backgroundSavePending, backgroundRestore == nil else { return }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        endBackgroundTaskHandler(backgroundTask)
        backgroundTask = .invalid
    }
}
#endif
