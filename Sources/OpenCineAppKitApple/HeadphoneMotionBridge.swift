#if os(iOS)
    import CoreMotion
    import OpenCineMotion
    import UIKit
    import os

    /// What the head-track bridge reads and drives. Each app adapts its model and camera session;
    /// differences between apps live in the adapter, never here.
    @MainActor
    public protocol HeadTrackHost: AnyObject {
        var headTrackingEnabled: Bool { get }
        var hapticsEnabled: Bool { get }
        /// The operator is holding the gimbal stick or pad.
        var gimbalAnalogHeld: Bool { get }
        /// Live, controllable and not covered by an editor or sheet: head motion may move the gimbal.
        var headTrackCanDrive: Bool { get }
        var isLiveVideoStale: Bool { get }
        var controlNote: String? { get set }
        var headTrackControlTitle: String { get set }
        var headTrackImuReadout: String { get set }
        var headTrackAxisPose: HeadTrackAxisPose? { get set }
        var freshGimbalWaypoint: GimbalWaypoint? { get }
        var gimbalYawTenthDeg: Int16? { get }
        var gimbalPitchTenthDeg: Int16? { get }
        var gimbalAttitudeHex: String { get }
        var gimbalAttitudeDump: String { get }
        func beginNativeHeadTrack() -> UInt64?
        func updateNativeHeadTrack(target: GimbalWaypoint, token: UInt64, measuredAt: TimeInterval?) -> Bool
        func endNativeHeadTrack(token: UInt64)
    }

    /// SET-relative yaw/pitch for the live debug rings (head + gimbal).
    public struct HeadTrackAxisPose: Equatable, Sendable {
        public var yawDeg: Double
        public var pitchDeg: Double
        public var gimbalYawDeg: Double?
        public var gimbalPitchDeg: Double?
        public var locked: Bool

        public init(yawDeg: Double, pitchDeg: Double, gimbalYawDeg: Double?, gimbalPitchDeg: Double?, locked: Bool) {
            self.yawDeg = yawDeg
            self.pitchDeg = pitchDeg
            self.gimbalYawDeg = gimbalYawDeg
            self.gimbalPitchDeg = gimbalPitchDeg
            self.locked = locked
        }
    }

    /// Calibrate Head Lock captures shared forward and camera-native pitch.
    /// Nose direction maps to absolute targets; roll remains display-only.
    @MainActor
    public final class HeadphoneMotionBridge: NSObject, CMHeadphoneMotionManagerDelegate {
        /// Optional axis rings and IMU/native-target readout. Diagnostic logs
        /// remain throttled independently of this operator display.
        public static let debugHud = false
        public static let calibrateTitle = "Calibrate Head Lock"
        public static let stopTitle = "STOP"

        private struct HeadSample: Sendable {
            var measuredAt: TimeInterval
            var sequence: UInt64
            var w: Double
            var x: Double
            var y: Double
            var z: Double
            var gx: Double
            var gy: Double
            var gz: Double
            var yaw: Double
            var pitch: Double
            var roll: Double
            var quat: HeadTrack.Quat { HeadTrack.Quat(w: w, x: x, y: y, z: z) }
        }

        private weak var host: (any HeadTrackHost)?
        private let motion: CMHeadphoneMotionManager
        private let authorizationStatus: () -> CMAuthorizationStatus
        nonisolated private let uptime: @Sendable () -> TimeInterval
        private let appName: String
        private let sampleInterval: TimeInterval
        private let hudInterval: TimeInterval
        private let log: (String) -> Void
        private let startupLog: (String) -> Void
        private let motionQueue: OperationQueue = {
            let q = OperationQueue()
            q.name = "opv.head-track"
            q.maxConcurrentOperationCount = 1
            q.qualityOfService = .userInteractive
            return q
        }()
        private struct HeadInbox: Sendable {
            var sample: HeadSample?
            var gate = HeadTrackNativeSampleGate()
            var accepted: UInt64 = 0
            var rejected: UInt64 = 0
            /// Rejection reasons for the `head-motion` row: measurement older than
            /// 200 ms, stamped in the future (clock-base mismatch), or superseded
            /// (old generation / not newer than the last sample).
            var rejectedStale: UInt64 = 0
            var rejectedFuture: UInt64 = 0
            var rejectedOther: UInt64 = 0
            var lastRejectedAgeMs: Int?
        }
        nonisolated private let latestHead = OSAllocatedUnfairLock(initialState: HeadInbox())
        private var samplePump: Task<Void, Never>?
        // Core Motion's active flag describes sample delivery, not ownership of a
        // request that is still waiting for authorization or its first sample.
        private var requestedGeneration: UInt64?
        private var requestedAt: TimeInterval?
        private var motionFailed = false
        private var lastStartupLogAt: TimeInterval?
        private var didToastStartupWaiting = false
        private var motionWaitingNote: String?
        private static let explicitRetrySilence: TimeInterval = 5
        private var originQuat = HeadTrack.Quat.identity
        private var originYaw = 0.0
        private var originPitch = 0.0
        private var originRoll = 0.0
        private var lastYaw = 0.0
        private var lastPitch = 0.0
        private var lastRoll = 0.0
        private var lastQuat = HeadTrack.Quat.identity
        private var lastGx = 0.0
        private var lastGy = 0.0
        private var lastGz = 0.0
        private var biasGx = 0.0
        private var biasGy = 0.0
        private var biasGz = 0.0
        private var intGx = 0.0
        private var intGy = 0.0
        private var intGz = 0.0
        private var didToastStill = false
        private var haveHead = false
        private var didToastNeedPods = false
        private var userStopped = false
        private var calibratedByUser = false
        private var pendingCalibrate = false
        private var lastMotionAt: Date?
        private var lastHudAt: Date?
        private var lastLogAt: Date?
        private var centerHaptic = UIImpactFeedbackGenerator(style: .medium)
        private var track: HeadTrackNative
        private var nativeToken: UInt64?
        private var lastHeadMeasuredAt: TimeInterval?
        private var lastHeadSequence: UInt64?
        private var didToastStaleHead = false
        private var driving = false
        private var gimbalYaw0Deg = 0.0
        private var gimbalPitch0Deg = 0.0
        private var didToastLive = false

        /// `appName` names the app in the Motion & Fitness permission note; `bounds` is the reach
        /// the gimbal targets stay in. `sampleInterval` is the gimbal stream period the head pose
        /// is pulled at; `hudInterval` throttles the readout. `startupLog` defaults to `log`.
        public init(
            appName: String,
            bounds: MotionBounds,
            sampleInterval: TimeInterval,
            hudInterval: TimeInterval,
            log: @escaping (String) -> Void,
            motion: CMHeadphoneMotionManager = CMHeadphoneMotionManager(),
            authorizationStatus: @escaping () -> CMAuthorizationStatus = CMHeadphoneMotionManager
                .authorizationStatus,
            uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            startupLog: ((String) -> Void)? = nil
        ) {
            self.appName = appName
            self.track = HeadTrackNative(bounds: bounds)
            self.sampleInterval = sampleInterval
            self.hudInterval = hudInterval
            self.log = log
            self.motion = motion
            self.authorizationStatus = authorizationStatus
            self.uptime = uptime
            self.startupLog = startupLog ?? log
            super.init()
        }

        /// Source measurement accepted by the callback fence, before the UI pump.
        public var receivedHeadSampleAt: TimeInterval? { latestHead.withLock { $0.sample?.measuredAt } }

        public func attach(host: any HeadTrackHost) {
            detach()
            self.host = host
            motion.delegate = self
            sync()
        }

        public func detach() {
            stopMotion()
            motionFailed = false
            haveHead = false
            didToastNeedPods = false
            didToastStill = false
            userStopped = false
            calibratedByUser = false
            pendingCalibrate = false
            lastMotionAt = nil
            driving = false
            track.reset()
            didToastLive = false
            host?.headTrackControlTitle = Self.calibrateTitle
            host?.headTrackImuReadout = ""
            host?.headTrackAxisPose = nil
            motion.delegate = nil
            host = nil
        }

        public func noteBlocked() {
            stopDrive()
        }

        public func sync() {
            guard let host else { return }
            guard host.headTrackingEnabled else {
                stopMotion()
                motionFailed = false
                haveHead = false
                didToastNeedPods = false
                didToastStill = false
                userStopped = false
                calibratedByUser = false
                pendingCalibrate = false
                lastMotionAt = nil
                driving = false
                track.reset()
                didToastLive = false
                host.headTrackControlTitle = Self.calibrateTitle
                host.headTrackImuReadout = ""
                host.headTrackAxisPose = nil
                return
            }
            publishTitle()
            startMotion()
            if haveHead { publishReadout(now: Date()) }
            if canDrive, !userStopped, calibratedByUser { apply(dt: 0) } else { stopDrive() }
        }

        public func tapControl() {
            guard let host, host.headTrackingEnabled else { return }
            if !userStopped, calibratedByUser {
                userStopped = true
                calibratedByUser = false
                pendingCalibrate = false
                track.reset()
                stopDrive()
                resetRelative()
                host.controlNote = "Head lock cleared"
                log("head-track: stopped")
                publishTitle()
                publishReadout(now: Date())
                return
            }
            userStopped = false
            pendingCalibrate = true
            motionFailed = false
            // Retry only on an operator tap after an authorized stream has stayed
            // silent. Pending permission keeps its original request and callback.
            if authorizationStatus() == .authorized, let requestedAt,
                uptime() - (receivedHeadSampleAt ?? requestedAt) >= Self.explicitRetrySilence
            {
                stopMotionUpdates()
            }
            startMotion()
            if haveHead,
                HeadTrackNative.headSampleIsFresh(measuredAt: receivedHeadSampleAt, now: uptime())
            {
                completeCalibrate()
            } else {
                publishMotionWaitingNote()
            }
        }

        private func completeCalibrate() {
            guard let host, pendingCalibrate, haveHead, canDrive, !host.gimbalAnalogHeld,
                HeadTrackNative.headSampleIsFresh(measuredAt: lastHeadMeasuredAt, now: uptime())
            else { return }
            guard let pose = host.freshGimbalWaypoint else {
                host.controlNote = "Head tracking waiting for gimbal"
                return
            }
            switch track.center(
                pose: pose,
                gyroLookRight: lastGx, gyroLookUp: lastGy, gyroYaw: lastGz)
            {
            case .waitingForGimbal:
                host.controlNote = "Head tracking waiting for gimbal"
                return
            case .waitingForStill:
                if !didToastStill {
                    didToastStill = true
                    host.controlNote = "Hold still to set forward"
                }
                return
            case .centered:
                break
            }
            originYaw = lastYaw
            originPitch = lastPitch
            originRoll = lastRoll
            originQuat = lastQuat
            gimbalYaw0Deg = pose.yawDeg
            gimbalPitch0Deg = pose.pitchDeg
            biasGx = lastGx
            biasGy = lastGy
            biasGz = lastGz
            intGx = 0
            intGy = 0
            intGz = 0
            pendingCalibrate = false
            calibratedByUser = true
            didToastLive = true
            host.controlNote = "Head lock set. Gimbal follows"
            log("head-track: calibrated")
            if host.hapticsEnabled { centerHaptic.impactOccurred() }
            lastMotionAt = Date()
            publishTitle()
            apply(dt: 0)
            publishReadout(now: lastMotionAt)
        }

        private func resetRelative() {
            originYaw = lastYaw
            originPitch = lastPitch
            originRoll = lastRoll
            originQuat = lastQuat
            intGx = 0
            intGy = 0
            intGz = 0
            lastMotionAt = Date()
        }

        private func publishTitle() {
            host?.headTrackControlTitle =
                (!userStopped && calibratedByUser)
                ? Self.stopTitle
                : Self.calibrateTitle
        }

        nonisolated public func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
            Task { @MainActor in
                log("head-track: AirPods connected")
                self.didToastNeedPods = false
                self.sync()
            }
        }

        nonisolated public func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
            Task { @MainActor in
                log("head-track: AirPods disconnected")
                self.stopMotionUpdates()
                self.stopSamplePump()
                self.lastHeadMeasuredAt = nil
                self.lastHeadSequence = nil
                self.haveHead = false
                self.calibratedByUser = false
                self.pendingCalibrate = false
                self.lastMotionAt = nil
                self.track.reset()
                self.stopDrive()
                self.host?.headTrackImuReadout = ""
                self.host?.headTrackAxisPose = nil
                self.publishTitle()
                if self.host?.headTrackingEnabled == true {
                    self.host?.controlNote =
                        "Headphone motion disconnected. Reconnect headphones"
                }
            }
        }

        private func startMotion() {
            let auth = authorizationStatus()
            defer { logStartupIfDue(now: uptime()) }
            if auth == .denied || auth == .restricted {
                stopMotion()
                if !didToastNeedPods {
                    didToastNeedPods = true
                    host?.controlNote = "Allow Motion & Fitness for \(appName) in Settings"
                }
                return
            }
            guard !motionFailed else { return }
            // Connection-status updates are iOS 18+; on iOS 17 the selector is missing
            // and calling it raises an ObjC exception (observed on iPadOS 17.7).
            if #available(iOS 18.0, *), !motion.isConnectionStatusActive {
                motion.startConnectionStatusUpdates()
            }
            guard motion.isDeviceMotionAvailable else {
                if host?.headTrackingEnabled == true, !didToastNeedPods {
                    didToastNeedPods = true
                    host?.controlNote = "Connect headphones that support motion tracking"
                }
                return
            }
            startSamplePump()
            guard requestedGeneration == nil else { return }
            let generation = latestHead.withLock {
                $0.sample = nil
                $0.accepted = 0
                $0.rejected = 0
                $0.rejectedStale = 0
                $0.rejectedFuture = 0
                $0.rejectedOther = 0
                $0.lastRejectedAgeMs = nil
                return $0.gate.begin()
            }
            requestedGeneration = generation
            requestedAt = uptime()
            didToastStartupWaiting = false
            publishMotionWaitingNote()
            // Core Motion calls this on motionQueue: no main-actor isolation, or Swift 6 traps on
            // entry (OPENPOCKETCINE-IOS-3N). The body touches only the nonisolated sample inbox.
            motion.startDeviceMotionUpdates(to: motionQueue) { @Sendable [weak self] sample, error in
                if let error {
                    Task { @MainActor in
                        guard let self else { return }
                        let current = self.latestHead.withLock {
                            guard $0.gate.isCurrent(generation) else { return false }
                            $0.sample = nil
                            return true
                        }
                        guard current else { return }
                        self.log("head-track: motion error code=\((error as NSError).code)")
                        self.stopMotion()
                        self.motionFailed = true
                        self.calibratedByUser = false
                        self.pendingCalibrate = false
                        self.track.reset()
                        self.publishTitle()
                        self.publishMotionWaitingNote()
                    }
                    return
                }
                guard let sample, let self else { return }
                let q = sample.attitude.quaternion
                let r = sample.rotationRate
                let a = sample.attitude
                let measurement = HeadSample(
                    measuredAt: sample.timestamp, sequence: 0,
                    w: q.w, x: q.x, y: q.y, z: q.z,
                    gx: r.x, gy: r.y, gz: r.z,
                    yaw: a.yaw, pitch: a.pitch, roll: a.roll)
                self.latestHead.withLock {
                    var next = measurement
                    let now = self.uptime()
                    guard
                        $0.gate.accepts(generation, measuredAt: next.measuredAt, now: now),
                        next.measuredAt > ($0.sample?.measuredAt ?? -.infinity)
                    else {
                        $0.rejected &+= 1
                        let age = now - next.measuredAt
                        if !$0.gate.isCurrent(generation) || !age.isFinite {
                            $0.rejectedOther &+= 1
                        } else if age < 0 {
                            $0.rejectedFuture &+= 1
                        } else if age > HeadTrackNative.maxHeadSampleAge {
                            $0.rejectedStale &+= 1
                        } else {
                            $0.rejectedOther &+= 1
                        }
                        if age.isFinite { $0.lastRejectedAgeMs = Int((age * 1_000).rounded()) }
                        return
                    }
                    $0.accepted &+= 1
                    next.sequence = ($0.sample?.sequence ?? 0) &+ 1
                    $0.sample = next
                }
            }
        }

        private func publishMotionWaitingNote() {
            let auth = authorizationStatus()
            let note: String
            if auth == .denied || auth == .restricted {
                note = "Allow Motion & Fitness for \(appName) in Settings"
            } else if auth == .notDetermined, motion.isDeviceMotionAvailable {
                note = "Allow Motion & Fitness to start head tracking"
            } else if motionFailed {
                note = "Headphone motion stopped. Tap Calibrate to retry"
            } else if !motion.isDeviceMotionAvailable {
                note = "Connect headphones that support motion tracking"
            } else if let requestedAt,
                uptime() - (receivedHeadSampleAt ?? requestedAt) >= Self.explicitRetrySilence
            {
                note = "No headphone motion. Tap Calibrate to retry"
            } else {
                note = "Waiting for headphone motion"
            }
            host?.controlNote = note
            motionWaitingNote = note
        }

        /// Once per second at most, including permission-pending startup silence.
        /// Counts are cumulative within this request; measurements/identities stay out.
        private func logStartupIfDue(now: TimeInterval) {
            if let lastStartupLogAt, now - lastStartupLogAt < 1 { return }
            lastStartupLogAt = now
            let snapshot = latestHead.withLock { $0 }
            let age = snapshot.sample.map { String(format: "%.0f", max(0, now - $0.measuredAt) * 1_000) } ?? "-"
            // Reasons make a zero-accepted report diagnosable: `future` with a large
            // negative age is a Core Motion clock mismatch, `stale` is late delivery.
            startupLog(
                "head-motion: generation=\(requestedGeneration.map(String.init) ?? "-") requested=\(requestedGeneration == nil ? 0 : 1) auth=\(Self.authLabel(authorizationStatus())) available=\(motion.isDeviceMotionAvailable ? 1 : 0) active=\(motion.isDeviceMotionActive ? 1 : 0) accepted=\(snapshot.accepted) rejected=\(snapshot.rejected) stale=\(snapshot.rejectedStale) future=\(snapshot.rejectedFuture) other=\(snapshot.rejectedOther) lastRejectAgeMs=\(snapshot.lastRejectedAgeMs.map(String.init) ?? "-") sampleAgeMs=\(age)"
            )
        }

        private func startSamplePump() {
            guard samplePump == nil else { return }
            let delay = Duration.milliseconds(Int((sampleInterval * 1_000).rounded(.up)))
            samplePump = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: delay)
                    guard let self, !Task.isCancelled else { return }
                    self.pullHead()
                }
            }
        }

        private func stopSamplePump() {
            samplePump?.cancel()
            samplePump = nil
        }

        private func pullHead() {
            let nowUptime = uptime()
            logStartupIfDue(now: nowUptime)
            guard let sample = latestHead.withLock({ $0.sample }),
                HeadTrackNative.headSampleIsFresh(measuredAt: sample.measuredAt, now: nowUptime)
            else {
                stopDrive()
                if calibratedByUser, !didToastStaleHead {
                    didToastStaleHead = true
                    host?.controlNote = "Head motion lost. Waiting for AirPods"
                }
                if requestedGeneration != nil, !didToastStartupWaiting,
                    authorizationStatus() == .authorized, let requestedAt,
                    nowUptime - (receivedHeadSampleAt ?? requestedAt) >= Self.explicitRetrySilence
                {
                    didToastStartupWaiting = true
                    publishMotionWaitingNote()
                }
                return
            }
            if !pendingCalibrate, !calibratedByUser,
                let motionWaitingNote, host?.controlNote == motionWaitingNote
            {
                host?.controlNote = "Headphone motion ready. Tap Calibrate"
            }
            motionWaitingNote = nil
            didToastStaleHead = false
            didToastStartupWaiting = false
            if sample.sequence == lastHeadSequence {
                if calibratedByUser { apply(dt: 0) }
                return
            }
            lastHeadSequence = sample.sequence
            lastHeadMeasuredAt = sample.measuredAt
            lastGx = sample.gx
            lastGy = sample.gy
            lastGz = sample.gz
            lastYaw = sample.yaw
            lastPitch = sample.pitch
            lastRoll = sample.roll
            lastQuat = sample.quat
            if !haveHead {
                resetRelative()
            }
            haveHead = true
            didToastNeedPods = false
            let now = Date()
            var dt = 0.0
            if let last = lastMotionAt {
                dt = now.timeIntervalSince(last)
                if dt < 0 || dt > 0.25 { dt = 0 }
            }
            lastMotionAt = now
            if calibratedByUser, dt > 0 {
                let toDeg = 180 / Double.pi
                intGx += (lastGx - biasGx) * dt * toDeg
                intGy += (lastGy - biasGy) * dt * toDeg
                intGz += (lastGz - biasGz) * dt * toDeg
            }
            if pendingCalibrate, !calibratedByUser {
                completeCalibrate()
            } else if calibratedByUser {
                apply(dt: dt)
            }
            publishReadout(now: now)
        }

        private var canDrive: Bool { host?.headTrackCanDrive ?? false }

        private func apply(dt: TimeInterval) {
            guard let host, host.headTrackingEnabled, haveHead, !userStopped else {
                stopDrive()
                return
            }
            guard canDrive else {
                stopDrive()
                return
            }
            if !calibratedByUser || !track.isCentered {
                stopDrive()
                return
            }
            if host.gimbalAnalogHeld {
                stopDrive()
                return
            }
            if host.isLiveVideoStale {
                stopDrive()
                return
            }
            guard
                HeadTrackNative.headSampleIsFresh(
                    measuredAt: lastHeadMeasuredAt, now: uptime()),
                host.freshGimbalWaypoint != nil
            else {
                stopDrive()
                return
            }
            let look = HeadTrack.look(current: lastQuat, origin: originQuat)
            guard let target = track.target(lookRightDeg: look.right, lookUpDeg: look.up) else {
                stopDrive()
                return
            }
            if nativeToken == nil { nativeToken = host.beginNativeHeadTrack() }
            guard let token = nativeToken else { return }
            guard host.updateNativeHeadTrack(
                target: target, token: token, measuredAt: lastHeadMeasuredAt) else {
                stopDrive()
                return
            }
            driving = true
        }

        private func stopDrive() {
            driving = false
            guard let token = nativeToken else { return }
            nativeToken = nil
            host?.endNativeHeadTrack(token: token)
        }

        private func invalidateHeadCallbacks() {
            latestHead.withLock {
                $0.gate.invalidate()
                $0.sample = nil
            }
        }

        private func stopMotion() {
            stopMotionUpdates()
            stopDrive()
            stopSamplePump()
            lastHeadMeasuredAt = nil
            lastHeadSequence = nil
            if #available(iOS 18.0, *), motion.isConnectionStatusActive {
                motion.stopConnectionStatusUpdates()
            }
        }

        private func stopMotionUpdates() {
            let hadRequest = requestedGeneration != nil
            requestedGeneration = nil
            requestedAt = nil
            invalidateHeadCallbacks()
            haveHead = false
            lastHeadMeasuredAt = nil
            lastHeadSequence = nil
            lastMotionAt = nil
            if hadRequest || motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
        }

        private func publishReadout(now: Date?) {
            // Per headphone motion sample. Unchanged writes (nil / "" with the
            // debug HUD off) re-rendered the live chrome at the motion rate.
            guard let host, host.headTrackingEnabled, haveHead else {
                if host?.headTrackImuReadout.isEmpty == false { host?.headTrackImuReadout = "" }
                if host?.headTrackAxisPose != nil { host?.headTrackAxisPose = nil }
                return
            }
            let look = HeadTrack.look(current: lastQuat, origin: originQuat)
            let lookRight = look.right
            let lookUp = look.up
            let originGimbalYaw = calibratedByUser ? gimbalYaw0Deg : 0
            let originGimbalPitch = calibratedByUser ? gimbalPitch0Deg : 0
            let gimbalYawDeg = host.gimbalYawTenthDeg.map {
                HeadTrack.bodyLookRightDeg(
                    liveYawDeg: Double($0) / 10, originYawDeg: originGimbalYaw)
            }
            let gimbalPitchDeg = host.gimbalPitchTenthDeg.map {
                HeadTrack.bodyLookUpDeg(
                    livePitchDeg: Double($0) / 10, originPitchDeg: originGimbalPitch)
            }
            let axisPose =
                Self.debugHud
                ? HeadTrackAxisPose(
                    yawDeg: lookRight, pitchDeg: lookUp,
                    gimbalYawDeg: gimbalYawDeg, gimbalPitchDeg: gimbalPitchDeg,
                    locked: calibratedByUser)
                : nil
            if host.headTrackAxisPose != axisPose { host.headTrackAxisPose = axisPose }
            let hudDue: Bool
            if let now, let last = lastHudAt {
                hudDue = now.timeIntervalSince(last) >= hudInterval
            } else {
                hudDue = true
            }
            let logDue: Bool
            if let now, let last = lastLogAt {
                logDue = now.timeIntervalSince(last) >= 0.5
            } else {
                logDue = true
            }
            guard hudDue || logDue else { return }

            let dY = lookRight
            let dP = lookUp
            let dR = HeadTrack.wrapDeg(
                HeadTrack.radToDeg(lastRoll) - HeadTrack.radToDeg(originRoll))
            let bodyY = gimbalYawDeg ?? 0
            let bodyP = gimbalPitchDeg ?? 0
            // Native target, SET-relative like the measured body pose.
            let predY =
                calibratedByUser ? (track.lastTarget?.yawDeg ?? gimbalYaw0Deg) - gimbalYaw0Deg : 0
            let predP =
                calibratedByUser ? (track.lastTarget?.pitchDeg ?? gimbalPitch0Deg) - gimbalPitch0Deg : 0
            let rawY = host.gimbalYawTenthDeg.map { String($0) } ?? "-"
            let rawP = host.gimbalPitchTenthDeg.map { String($0) } ?? "-"
            let setMark = calibratedByUser ? "SET" : "no SET"
            if hudDue {
                lastHudAt = now
                let readout =
                    Self.debugHud
                    ? String(
                        format:
                            "%@  shared °\nhead   Y%+6.1f  P%+6.1f  R%+6.1f\nbody   Y%+6.1f  P%+6.1f  rawP %@\ntarget Y%+6.1f  P%+6.1f\nerr    Y%+6.1f  P%+6.1f",
                        setMark, dY, dP, dR, bodyY, bodyP, rawP, predY, predP, dY - predY,
                        dP - predP)
                    : ""
                if host.headTrackImuReadout != readout { host.headTrackImuReadout = readout }
            }
            if logDue {
                lastLogAt = now
                let att = host.gimbalAttitudeHex
                let dump = host.gimbalAttitudeDump
                log(
                    String(
                        format:
                            "head-imu: %@ head Y=%.1f P=%.1f R=%.1f  body Y=%.1f P=%.1f  target Y=%.1f P=%.1f  err Y=%.1f P=%.1f  rawY=%@ rawP=%@ %@ att=%@",
                        setMark, dY, dP, dR, bodyY, bodyP, predY, predP, dY - predY, dP - predP,
                        rawY, rawP, dump.isEmpty ? "-" : dump, att.isEmpty ? "-" : att)
                )
            }
        }

        private static func authLabel(_ status: CMAuthorizationStatus) -> String {
            switch status {
            case .notDetermined: "notDetermined"
            case .restricted: "restricted"
            case .denied: "denied"
            case .authorized: "authorized"
            @unknown default: "unknown"
            }
        }
    }
#endif
