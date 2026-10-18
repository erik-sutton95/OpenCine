import Foundation
import OpenCineCore
import OpenCineDJI
import OpenCineMotion

/// The datalink calls the gimbal owner makes. `DjiAppleDatalink` is the product link.
@MainActor public protocol DjiAppleGimbalLink: AnyObject {
    var isClosed: Bool { get }
    func send(_ frame: Duml.Frame) -> UInt16
    func sendUntracked(_ frame: Duml.Frame) -> UInt16
    func noteGimbalStick(axis0: UInt16, axis1: UInt16)
    func restGimbalStick()
    func beginNativeTargets(token: UInt64)
    func noteNativeTarget(_ frame: Duml.Frame, token: UInt64) -> Bool
    func endNativeTargets(token: UInt64)
    func startNativeProgram(
        program: GimbalProgram, token: UInt64, zoom: GimbalProgramZoom?,
        onProgress: @escaping @MainActor @Sendable (UInt64, GimbalMoveEngine, GimbalWaypoint) -> Void
    ) -> Bool
    func pauseNativeProgram(token: UInt64) -> Bool
    func resumeNativeProgram(token: UInt64) -> Bool
    func cancelNativeProgram(token: UInt64) -> Bool
}

/// Session facts the gimbal owner reads when it decides, and the observable gimbal state it
/// writes. Picture flip, zoom retirement and the journal stay host policy.
@MainActor public protocol DjiAppleGimbalHost: AnyObject {
    var gimbalLink: (any DjiAppleGimbalLink)? { get }
    var hasGimbal: Bool { get }
    var isLocked: Bool { get }
    var isLivePhase: Bool { get }
    var sessionRecovery: SessionRecoveryState { get }
    var gimbalControlSceneActive: Bool { get }
    var isFeedWarming: Bool { get }
    var holdsMonitor: Bool { get }
    var isLiveVideoStale: Bool { get }
    var isBrowsingMedia: Bool { get }
    var zoomReadout: Double { get }
    var status: CameraStatus { get }
    var cameraModel: CameraModel? { get }
    var gimbalRamp: GimbalRamp { get }
    var gimbalDoubleTap: GimbalDoubleTap { get }
    var gimbalMode: GimbalMode { get set }
    var gimbalSpeed: GimbalSpeed { get set }
    var gimbalProgram: GimbalProgram { get set }
    var gimbalMoveRunning: Bool { get set }
    var gimbalMovePaused: Bool { get set }
    var gimbalMoveCanPause: Bool { get set }
    var gimbalStartCountdown: Int? { get set }
    var gimbalPoseViewFlip: Bool { get set }
    var gimbalPoseInvertPan: Bool { get set }
    var gimbalLimitPulse: UInt { get set }
    var gimbalLimitContact: GimbalLimitWatch.Contact { get set }
    var gimbalLimitPanSign: Double { get set }
    var gimbalLimitTiltSign: Double { get set }
    var controlNote: String? { get set }
    func gimbalLog(_ line: String)
    /// After every pose sync; the host applies the view flip to its picture.
    func gimbalPoseDidSync(viewFlip: Bool)
    /// Retires manual zoom before a take that changes zoom; `false` stops the take.
    func retireZoomForProgrammedMove() -> Bool
}

/// Stick stream, mode and speed with their readback pins, pose mapping, limit and world level,
/// head-track targets and programmed moves over the native datalink. Rest and stop are always
/// sent; mode and speed SETs are untracked.
@MainActor public final class DjiAppleGimbalControl {
    public private(set) var stickMapping = GimbalStickMapping()
    /// World level from the attitude quaternion. LEVEL polls it at 10 Hz.
    public private(set) var levelReading = LevelReading()
    /// Last `0x04/0x05` hex + i16 dump (pitch-field hunt; payload is ~50 B).
    public private(set) var lastAttitudeHex = ""
    public private(set) var lastAttitudeDump = ""
    public private(set) var stickHeld = false
    public private(set) var lastStickAt: Date?
    /// Last non-rest throw. Motion can pause HEVC.
    public private(set) var lastThrowAt: Date?

    private weak var host: (any DjiAppleGimbalHost)?
    private let uptime: () -> TimeInterval
    private let wall: () -> Date
    private let sleep: (Duration) async throws -> Void
    private var modePin: CameraValuePin<GimbalMode>?
    private var speedPin: CameraValuePin<GimbalSpeed>?
    private var followFamilyConfirmed = false
    private var limitWatch = GimbalLimitWatch()
    private var lastCommand = (x: 0.0, y: 0.0)
    private var rampFilter = GimbalRampFilter()
    private var paramPoll = GimbalParamPoll()
    /// Operator speed/tilt lock held while head tracking or Motion Control runs on Fast.
    private var prep = GimbalPrepRestore()
    /// In-flight Double-tap Level move, judged on each attitude push.
    private var worldLevelSnap: WorldLevelSnap?
    private var lastNativeWaypoint: GimbalWaypoint?
    private var overlayMotion = GimbalOverlayMotion()
    private var moveEngine = GimbalMoveEngine()
    private var moveTask: Task<Void, Never>?
    private var lastMoveAttitudeAt: TimeInterval?
    private var movePoseStableSince: TimeInterval?
    private var lastMoveObservedPose: GimbalWaypoint?
    private var moveDriving = false
    private var lastMoveLogAt: Date?
    private var wasRecording = false
    private var nativeTargetGeneration: UInt64 = 0
    private var nativeHeadToken: UInt64?
    private var nativeMoveToken: UInt64?

    public init(
        host: any DjiAppleGimbalHost,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wall: @escaping () -> Date = { Date() },
        sleep: @escaping (Duration) async throws -> Void = hostSleep(for:)
    ) {
        self.host = host
        self.uptime = uptime
        self.wall = wall
        self.sleep = sleep
    }

    public var liveWaypoint: GimbalWaypoint? {
        guard var point = lastNativeWaypoint, let host else { return nil }
        point.zoom = host.zoomReadout
        return point
    }

    public var freshWaypoint: GimbalWaypoint? {
        guard let received = lastMoveAttitudeAt, uptime() - received <= 0.3,
            let pose = liveWaypoint, let native = pose.nativePitchDeg,
            native.isFinite, (-180...180).contains(native)
        else { return nil }
        return pose
    }

    public var overlayWaypoint: GimbalWaypoint? {
        guard let host, !host.isLiveVideoStale, var pose = overlayMotion.pose(at: uptime())
        else { return nil }
        pose.zoom = host.zoomReadout
        return pose
    }

    public func beginNativeHeadTrack() -> UInt64? {
        guard let host, host.isLivePhase, !host.sessionRecovery.isRecovering,
            host.gimbalControlSceneActive, !host.isFeedWarming, host.hasGimbal, !host.isLocked,
            !host.gimbalMoveRunning, !stickHeld, !host.isBrowsingMedia, !host.isLiveVideoStale,
            freshWaypoint != nil, let link = host.gimbalLink
        else { return nil }
        cancelNativeHeadTrack()
        restStickWire()
        prepHeadTrack()
        noteAppMotion()
        nativeTargetGeneration &+= 1
        nativeHeadToken = nativeTargetGeneration
        link.beginNativeTargets(token: nativeTargetGeneration)
        return nativeTargetGeneration
    }

    public func updateNativeHeadTrack(target: GimbalWaypoint, token: UInt64) -> Bool {
        guard let host, host.isLivePhase, !host.sessionRecovery.isRecovering,
            host.gimbalControlSceneActive, nativeHeadToken == token, !host.gimbalMoveRunning,
            !stickHeld, !host.isLocked, !host.isBrowsingMedia, !host.isLiveVideoStale,
            let live = freshWaypoint, GimbalMoveEngine.canSendNativeTarget(from: live, to: target),
            let frame = Commands.gimbalTimedTarget(
                waypoint: target, duration: HeadTrackNative.commandDuration),
            let link = host.gimbalLink
        else {
            endNativeHeadTrack(token: token)
            return false
        }
        return link.noteNativeTarget(frame, token: token)
    }

    public func endNativeHeadTrack(token: UInt64) {
        guard nativeHeadToken == token else { return }
        nativeHeadToken = nil
        host?.gimbalLink?.endNativeTargets(token: token)
    }

    private func cancelNativeHeadTrack() {
        if let token = nativeHeadToken { endNativeHeadTrack(token: token) }
    }

    /// Stream `0x04/0x01` while the on-screen stick is held. No ACK. `x`/`y` are −1…1
    /// (right / up); `GimbalStick.encode` maps that onto tilt/pan. Invert follows the
    /// visible picture (Flip or 180, XOR MIRROR assist).
    public func updateStick(
        x: Double, y: Double, sensitivity: Int = GimbalStick.defaultSensitivity,
        assistMirror: Bool = false, linear: Bool = false,
        mapping: GimbalStick.Mapping = .defaults
    ) {
        guard let host, !host.isLocked else { return }
        guard host.gimbalLink != nil else { return }
        guard host.isLivePhase, host.gimbalControlSceneActive, !host.isFeedWarming,
            !host.sessionRecovery.isRecovering
        else {
            endStick(cancelMove: true)
            return
        }
        let restZone = linear ? GimbalStick.deadzone : mapping.deadzone
        if !linear, hypot(x, y) > restZone { cancelNativeHeadTrack() }
        if host.isLiveVideoStale, !moveDriving {
            endStick(cancelMove: true)
            return
        }
        if host.gimbalMoveRunning, !linear {
            guard hypot(x, y) > restZone else { return }
            cancelProgrammedMove()
        }
        var throwX = x
        var throwY = y
        if !linear {
            let rawDt = lastStickAt.map { wall().timeIntervalSince($0) } ?? GimbalStick.streamInterval
            let dt = min(max(rawDt, 0.001), 0.12)
            (throwX, throwY) = rampFilter.tick(targetX: x, targetY: y, ramp: host.gimbalRamp, dt: dt)
        }
        // Linear callers (programmed move, HeadTrack, calibrate) speak
        // `0x04/0x05` space: no screen-relative pan invert.
        let invert =
            linear
            ? false
            : GimbalStick.liveInvertPan(poseInvert: host.gimbalPoseInvertPan, assistMirror: assistMirror)
        let axes = GimbalStick.encode(
            x: throwX, y: throwY, invertPan: invert, sensitivity: sensitivity, linear: linear,
            mapping: linear ? .defaults : mapping)
        lastCommand = (x, y)
        lastStickAt = wall()
        if axes.axis0 != GimbalStick.center || axes.axis1 != GimbalStick.center {
            movePoseStableSince = nil
            lastThrowAt = wall()
            noteAppMotion()
        }
        if !stickHeld {
            stickHeld = true
            host.gimbalLog("control: gimbal stick stream invert=\(stickMapping.invertPan ? 1 : 0)")
        }
        host.gimbalLink?.noteGimbalStick(axis0: axes.axis0, axis1: axes.axis1)
        tickLimit()
    }

    /// Mimo Fast + tilt unlocked. Untracked: a tracked SET can skip while UDP is `.waiting`,
    /// and `0x4C` Follow can damp the stick. The operator's speed and tilt lock come back once
    /// the gimbal is idle.
    public func prepHeadTrack() {
        guard let host, !host.isLocked, let link = host.gimbalLink else { return }
        let seqs = prep.prep(speed: host.gimbalSpeed, mode: host.gimbalMode).map {
            link.sendUntracked($0)
        }
        host.gimbalLog(
            "head-track: gimbal Fast+unlock seq=\(seqs.map(String.init).joined(separator: ",")) restore speed=\(prep.speed?.label ?? "-") mode=\(prep.mode?.label ?? "-")"
        )
    }

    /// Before the link closes: do not leave the camera on Fast for the next session.
    public func restorePrepNow() { restorePrep(prep.restoreNow()) }

    /// Put back the speed/tilt lock that `prepHeadTrack` replaced. Pins keep a Fast readback
    /// already in flight from flashing in the menu.
    private func restorePrep(_ restore: GimbalPrepRestore.Restore?) {
        guard let restore, let host, let link = host.gimbalLink else { return }
        let now = wall().timeIntervalSinceReferenceDate
        if let speed = restore.speed {
            speedPin = CameraValuePin(speed, now: now)
            if host.gimbalSpeed != speed { host.gimbalSpeed = speed }
        }
        if restore.mode == .tiltLocked, host.gimbalMode == .follow {
            modePin = CameraValuePin(.tiltLocked, now: now)
            host.gimbalMode = .tiltLocked
        }
        let seqs = restore.frames.map { link.sendUntracked($0) }
        host.gimbalLog(
            "control: gimbal restore speed=\(restore.speed?.label ?? "-") mode=\(restore.mode?.label ?? "-") seq=\(seqs.map(String.init).joined(separator: ","))"
        )
    }

    /// On-screen stick double-tap and gamepad Circle/B, per the Double-tap setting.
    public func performDoubleTap() {
        switch host?.gimbalDoubleTap {
        case .recenter: recenter()
        case .level: levelToWorld()
        case nil: break
        }
    }

    /// Double-tap Level: one `0x04/0x14` move to the nearest world target (horizon or plumb),
    /// judged on the attitude quaternion. Roll is not commanded.
    public func levelToWorld() {
        guard let host, !host.isLocked else { return }
        let now = uptime()
        guard let tilt = levelReading.pitchDeg(now: now) else {
            host.controlNote = WorldLevelSnap.noLevelData
            return
        }
        guard let link = host.gimbalLink else { return }
        guard let pose = lastNativeWaypoint,
            let plan = WorldLevelSnap.plan(tiltDeg: tilt, pose: pose, now: now)
        else {
            host.controlNote = WorldLevelSnap.unreachableNote
            return
        }
        takeOver()
        worldLevelSnap = plan.snap
        let seq = link.send(plan.frame)
        host.gimbalLog(
            "control: send World level 0x04/0x14 seq=\(seq) tilt=\(String(format: "%.1f", tilt)) target=\(plan.snap.target) payload=\(Duml.hex(plan.frame.payload))"
        )
    }

    private func judgeWorldLevelSnap() {
        guard let snap = worldLevelSnap, let host else { return }
        // The operator or a programmed move took the gimbal: drop it silently.
        // A stick takeover also ends the camera's timed move so it cannot fight the stick.
        if stickHeld || host.gimbalMoveRunning {
            worldLevelSnap = nil
            if stickHeld { _ = host.gimbalLink?.sendUntracked(Commands.gimbalTimedStop()) }
            return
        }
        let now = uptime()
        let fpv = host.gimbalMode == .fpv ? WorldLevelSnap.fpvRollNote : ""
        switch snap.evaluate(tiltDeg: levelReading.pitchDeg(now: now), now: now) {
        case .pending:
            return
        case .expired:
            worldLevelSnap = nil
            return
        case .arrived:
            host.controlNote = snap.target.successNote + fpv
        case .failed(let error):
            _ = host.gimbalLink?.sendUntracked(Commands.gimbalTimedStop())
            host.controlNote = WorldLevelSnap.failureNote(errorDeg: error) + fpv
        }
        worldLevelSnap = nil
        host.gimbalLog("control: world level \(host.controlNote ?? "-")")
    }

    /// Stick double-tap (hardware joystick). Wire is Mimo's recenter button:
    /// `0x04/0x4C` `FE 08`. Mimo has no stick double-tap.
    public func recenter() {
        guard let host, !host.isLocked, host.gimbalLink != nil else { return }
        worldLevelSnap = nil
        takeOver()
        let frame = Commands.gimbalRecenter()
        let seq = host.gimbalLink?.send(frame) ?? 0
        host.gimbalLog(
            "control: send Gimbal recenter 0x04/0x4C seq=\(seq) flags=0x\(String(frame.flags, radix: 16)) payload=\(Duml.hex(frame.payload)) via=datalink"
        )
        host.controlNote = "Gimbal re-centered"
    }

    /// Stick triple-tap. `FE 09` is a 180.
    public func flip() {
        guard let host, !host.isLocked, host.gimbalLink != nil else { return }
        takeOver()
        stickMapping.noteRotate180()
        let frame = Commands.gimbalFlip()
        let seq = host.gimbalLink?.send(frame) ?? 0
        let m = stickMapping
        host.gimbalLog(
            "control: send Gimbal flip 0x04/0x4C seq=\(seq) flags=0x\(String(frame.flags, radix: 16)) payload=\(Duml.hex(frame.payload)) via=datalink invert=\(m.invertPan ? 1 : 0) face=\(m.face == .selfie ? "selfie" : m.face == .front ? "front" : "unknown") rot180=\(m.rotated180 ? 1 : 0) parity=\(m.rotateParity ? 1 : 0)"
        )
    }

    /// A one-shot body move replaces the stick and any take before it is sent.
    private func takeOver() {
        endStick(cancelMove: true)
        movePoseStableSince = nil
        lastMoveObservedPose = nil
        overlayMotion.reset()
        lastStickAt = wall()
    }

    /// Send center and stop the stream. Always fire: the camera needs rest.
    public func endStick(cancelMove: Bool = false, ifCurrent: () -> Bool = { true }) {
        guard ifCurrent() else { return }
        if cancelMove { cancelNativeHeadTrack() }
        guard ifCurrent() else { return }
        // Programmed movement owns the gimbal until it rests itself.
        if moveDriving && !cancelMove { return }
        if host?.gimbalMoveRunning == true {
            cancelProgrammedMove(ifCurrent: ifCurrent)
            return
        }
        restStickWire(ifCurrent: ifCurrent)
    }

    private func restStickWire(ifCurrent: () -> Bool = { true }) {
        guard ifCurrent() else { return }
        rampFilter.reset()
        lastCommand = (0, 0)
        limitWatch.reset()
        guard stickHeld else { return }
        lastStickAt = wall()
        stickHeld = false
        guard ifCurrent() else { return }
        host?.gimbalLog("control: gimbal stick rest")
        host?.gimbalLink?.restGimbalStick()
    }

    /// The link is going away: rest the stick and forget its stream.
    public func dropStick(ifCurrent: () -> Bool = { true }) {
        host?.gimbalLink?.restGimbalStick()
        guard ifCurrent() else { return }
        stickHeld = false
        guard ifCurrent() else { return }
        lastStickAt = nil
        lastThrowAt = nil
        lastCommand = (0, 0)
        limitWatch.reset()
    }

    public var canSetConfiguration: Bool {
        guard let host else { return false }
        return host.hasGimbal && !host.isLocked && host.isLivePhase && host.gimbalControlSceneActive
            && !host.isFeedWarming && !host.holdsMonitor && !host.sessionRecovery.isRecovering
            && !host.isLiveVideoStale && host.gimbalLink != nil && host.gimbalLink?.isClosed != true
    }

    public func setMode(_ mode: GimbalMode) {
        guard canSetConfiguration, let host else { return }
        cancelProgrammedMove()
        prep.mode = nil
        followFamilyConfirmed = false
        modePin = CameraValuePin(mode, now: wall().timeIntervalSinceReferenceDate)
        host.gimbalMode = mode
        for frame in GimbalControl.setModeFrames(mode) {
            let seq = host.gimbalLink?.sendUntracked(frame) ?? 0
            host.gimbalLog("control: send Gimbal mode \(mode.label) seq=\(seq) payload=\(Duml.hex(frame.payload))")
        }
    }

    public func setSpeed(_ speed: GimbalSpeed) {
        guard canSetConfiguration, let host else { return }
        cancelProgrammedMove()
        prep.speed = nil
        speedPin = CameraValuePin(speed, now: wall().timeIntervalSinceReferenceDate)
        host.gimbalSpeed = speed
        let frame = Commands.setGimbalSpeed(speed)
        let seq = host.gimbalLink?.sendUntracked(frame) ?? 0
        host.gimbalLog("control: send Gimbal speed \(speed.label) seq=\(seq) payload=\(Duml.hex(frame.payload))")
    }

    public func setWaypoint(_ slot: GimbalWaypointSlot) {
        guard let host, host.hasGimbal, !host.isLocked else { return }
        guard let point = liveWaypoint, point.nativePitchDeg != nil, point == point.clamped() else {
            host.controlNote = ControlHud.gimbalPoseNotReady
            return
        }
        let now = uptime()
        guard !host.gimbalMoveRunning, !stickHeld, let receivedAt = lastMoveAttitudeAt,
            now - receivedAt <= 0.3, let stableSince = movePoseStableSince,
            now - stableSince >= 0.5
        else {
            host.controlNote = ControlHud.gimbalHoldStill
            return
        }
        host.gimbalProgram.setPoint(slot, point)
    }

    public func clearWaypoint(_ slot: GimbalWaypointSlot) {
        guard let host else { return }
        cancelProgrammedMove()
        host.gimbalProgram[slot] = nil
        if !host.gimbalProgram.canRun { cancelProgrammedMove() }
    }

    public func setLegDuration(ab: TimeInterval? = nil, bc: TimeInterval? = nil) {
        guard let host else { return }
        if host.gimbalMoveRunning { cancelProgrammedMove() }
        if let ab {
            let floor = GimbalProgram.minTravelDuration(from: host.gimbalProgram.a, to: host.gimbalProgram.b)
            host.gimbalProgram.durationAB = GimbalProgram.snapDuration(max(ab, floor))
        }
        if let bc {
            let floor = GimbalProgram.minTravelDuration(from: host.gimbalProgram.b, to: host.gimbalProgram.c)
            host.gimbalProgram.durationBC = GimbalProgram.snapDuration(max(bc, floor))
        }
    }

    public func setSmoothness(_ value: Double) {
        guard value.isFinite, let host else { return }
        cancelProgrammedMove()
        host.gimbalProgram.smoothness = min(1, max(0, value))
    }

    public func clearProgram() {
        guard let host else { return }
        cancelProgrammedMove()
        host.gimbalProgram = GimbalProgram(
            durationAB: host.gimbalProgram.durationAB, durationBC: host.gimbalProgram.durationBC)
    }

    public func setLoop(_ enabled: Bool) {
        guard let host else { return }
        cancelProgrammedMove()
        host.gimbalProgram.loop = enabled
    }

    public var programmedZoomUnavailableReason: String? {
        guard let host else { return nil }
        return GimbalProgramZoom(program: host.gimbalProgram, model: host.cameraModel, status: host.status)
            .failureReason
    }

    public var canRunProgrammedMove: Bool {
        guard let host else { return false }
        let program = host.gimbalProgram
        return programmedZoomUnavailableReason == nil && !host.isFeedWarming && !host.isLiveVideoStale
            && program.canRun
            && [program.a, program.b, program.c].compactMap { $0 }.allSatisfy { $0.nativePitchDeg != nil }
    }

    public func runProgrammedMove() {
        guard let host, host.gimbalControlSceneActive, host.hasGimbal, !host.isLocked else { return }
        if host.gimbalMoveRunning {
            cancelProgrammedMove()
            return
        }
        if let reason = programmedZoomUnavailableReason {
            host.controlNote = reason
            return
        }
        guard canRunProgrammedMove, let live = liveWaypoint, live.nativePitchDeg != nil,
            let receivedAt = lastMoveAttitudeAt, uptime() - receivedAt <= 0.3
        else {
            host.controlNote = ControlHud.gimbalPoseNotReady
            return
        }
        let take = host.gimbalProgram
        var validation = GimbalMoveEngine()
        guard validation.start(program: take, live: live) else {
            host.controlNote = validation.failure ?? ControlHud.programmedMoveNeedAB
            return
        }
        moveEngine = validation
        if take.changesZoom {
            guard host.retireZoomForProgrammedMove() else { return }
        }
        host.controlNote = nil
        cancelNativeHeadTrack()
        restStickWire()
        host.gimbalMoveRunning = true
        host.gimbalMovePaused = false
        host.gimbalMoveCanPause = false
        host.gimbalStartCountdown = 3
        moveDriving = true
        lastMoveLogAt = nil
        moveTask?.cancel()
        moveTask = Task { @MainActor [weak self] in
            for remaining in (1...3).reversed() {
                guard let self, let host = self.host, !Task.isCancelled, host.gimbalMoveRunning
                else { return }
                host.gimbalStartCountdown = remaining
                do { try await self.sleep(.seconds(1)) } catch { return }
            }
            guard let self, let host = self.host, !Task.isCancelled, host.gimbalMoveRunning
            else { return }
            host.gimbalStartCountdown = nil
            self.prepHeadTrack()
            do { try await self.sleep(.milliseconds(250)) } catch { return }
            guard host.gimbalMoveRunning, host.gimbalControlSceneActive, !Task.isCancelled else {
                return
            }
            guard let link = host.gimbalLink else {
                self.cancelProgrammedMove()
                return
            }
            self.nativeTargetGeneration &+= 1
            let token = self.nativeTargetGeneration
            self.nativeMoveToken = token
            let zoom =
                take.changesZoom
                ? GimbalProgramZoom(program: take, model: host.cameraModel, status: host.status) : nil
            if let reason = zoom?.failureReason {
                self.cancelProgrammedMove()
                host.controlNote = reason
                return
            }
            let started = link.startNativeProgram(program: take, token: token, zoom: zoom) {
                [weak self] token, engine, pose in
                guard let self, let host = self.host, self.nativeMoveToken == token,
                    host.gimbalMoveRunning
                else { return }
                self.moveEngine = engine
                host.gimbalMovePaused = engine.isPaused
                host.gimbalMoveCanPause = engine.running
                self.logMotionProgress(live: pose, force: !engine.running)
                if !engine.running {
                    self.nativeMoveToken = nil
                    host.controlNote = engine.failure
                    host.gimbalMoveRunning = false
                    host.gimbalMovePaused = false
                    host.gimbalMoveCanPause = false
                    self.moveDriving = false
                    self.moveTask = nil
                    self.restStickWire()
                }
            }
            host.gimbalMoveCanPause = started
            if !started {
                host.controlNote = ControlHud.gimbalPoseNotReady
                self.cancelProgrammedMove()
            }
        }
    }

    public func restartProgrammedMove() {
        guard let host, host.gimbalControlSceneActive, !host.isLocked, host.gimbalMoveRunning,
            host.gimbalMovePaused
        else { return }
        cancelProgrammedMove()
        runProgrammedMove()
    }

    public func pauseOrResumeProgrammedMove() {
        guard let host, host.gimbalControlSceneActive, !host.isLocked, host.gimbalMoveRunning,
            let token = nativeMoveToken, let link = host.gimbalLink
        else { return }
        if host.gimbalMovePaused {
            guard link.resumeNativeProgram(token: token) else {
                host.controlNote = "Wait for the camera to settle, then resume"
                return
            }
            host.gimbalMovePaused = false
        } else {
            guard link.pauseNativeProgram(token: token) else { return }
            host.gimbalMovePaused = true
        }
        host.controlNote = nil
    }

    /// Each step re-checks `ifCurrent`: an observer of the published state may replace the
    /// session mid-cancel, and a retired caller must not clear its successor's facts.
    public func cancelProgrammedMove(ifCurrent: () -> Bool = { true }) {
        guard ifCurrent() else { return }
        cancelNativeHeadTrack()
        guard ifCurrent() else { return }
        let hadStream = nativeMoveToken != nil
        if let token = nativeMoveToken {
            nativeMoveToken = nil
            _ = host?.gimbalLink?.cancelNativeProgram(token: token)
        }
        guard ifCurrent(), let host else { return }
        moveTask?.cancel()
        moveTask = nil
        moveEngine.cancel()
        let was = host.gimbalMoveRunning
        host.gimbalStartCountdown = nil
        guard ifCurrent() else { return }
        host.gimbalMoveRunning = false
        guard ifCurrent() else { return }
        host.gimbalMovePaused = false
        guard ifCurrent() else { return }
        host.gimbalMoveCanPause = false
        guard ifCurrent() else { return }
        moveDriving = false
        if was {
            if !hadStream { _ = host.gimbalLink?.sendUntracked(Commands.gimbalTimedStop()) }
            guard ifCurrent() else { return }
            restStickWire(ifCurrent: ifCurrent)
            guard ifCurrent() else { return }
        }
        if let live = liveWaypoint {
            logMotionProgress(live: live, force: true)
        }
    }

    private func logMotionProgress(live: GimbalWaypoint, force: Bool) {
        guard let host else { return }
        let text = moveEngine.hudText(program: host.gimbalProgram, live: live)
        let now = wall()
        let logDue = lastMoveLogAt.map { now.timeIntervalSince($0) >= 0.5 } ?? true
        if logDue || force, !text.isEmpty {
            lastMoveLogAt = now
            host.gimbalLog("gimbal-move: \(text.replacingOccurrences(of: "\n", with: " | "))")
        }
    }

    /// New stream: the pose and its watches restart. The host then resets its picture flip
    /// and calls `syncPose()`.
    public func resetPose() {
        cancelProgrammedMove()
        lastMoveAttitudeAt = nil
        lastNativeWaypoint = nil
        overlayMotion.reset()
        movePoseStableSince = nil
        lastMoveObservedPose = nil
        paramPoll = GimbalParamPoll()
        stickMapping = GimbalStickMapping()
        lastCommand = (0, 0)
        limitWatch.reset()
    }

    /// Disconnect: pins, take and operator controls go back to the camera defaults.
    public func resetControls() {
        modePin = nil
        speedPin = nil
        cancelProgrammedMove()
        guard let host else { return }
        host.gimbalProgram = GimbalProgram()
        lastMoveAttitudeAt = nil
        lastNativeWaypoint = nil
        overlayMotion.reset()
        movePoseStableSince = nil
        lastMoveObservedPose = nil
        host.gimbalMode = .follow
        host.gimbalSpeed = .defaultSpeed
        paramPoll = GimbalParamPoll()
        rampFilter.reset()
        wasRecording = false
    }

    /// A borrowed tile hands its pose in so a Live View pan or TT180 survives.
    public func adoptPose(_ pose: GimbalStickMapping) {
        stickMapping = pose
        syncPose()
    }

    public func syncPose() {
        guard let host else { return }
        stickMapping.selfieFlip = host.status.selfieFlip?.isOn ?? false
        // Runs per gimbal attitude frame: an unchanged write still notifies
        // `livePictureViewFlip` readers and the stick pads.
        let viewFlip = stickMapping.poseViewFlip
        if host.gimbalPoseViewFlip != viewFlip { host.gimbalPoseViewFlip = viewFlip }
        let invertPan = stickMapping.invertPan
        if host.gimbalPoseInvertPan != invertPan { host.gimbalPoseInvertPan = invertPan }
        host.gimbalPoseDidSync(viewFlip: viewFlip)
    }

    /// Attitude `0x04/0x05` and face `0x04/0x27` pushes; `status` is the projected report
    /// before it is committed.
    public func ingest(_ frame: Duml.Frame, status s: CameraStatus) {
        guard let host, frame.cmdSet == 0x04 else { return }
        if frame.cmdId == 0x05 {
            if host.hasGimbal, host.gimbalLink != nil, paramPoll.shouldRequest(at: uptime()) {
                _ = host.gimbalLink?.sendUntracked(Commands.gimbalParamsGet())
            }
            if frame.payload.count == 50, let family = s.gimbalModeFamily {
                followFamilyConfirmed = family == .follow
                let resolved = GimbalControl.modeFromFamily(family, current: host.gimbalMode)
                // Follow-family alone cannot confirm the tilt-lock choice.
                let reportedMode: GimbalMode? = family == .follow ? nil : resolved
                // Per attitude frame: write only on change so the gimbal sheet
                // does not re-render at the attitude rate.
                let mode =
                    CameraValuePin.reconcile(
                        &modePin, reported: reportedMode, now: wall().timeIntervalSinceReferenceDate)
                    ?? resolved
                if mode != host.gimbalMode { host.gimbalMode = mode }
            }
            lastAttitudeHex = Duml.hex(frame.payload, limit: 80)
            lastAttitudeDump = GimbalStick.attitudeAngleDump(frame.payload)
            levelReading.ingest(frame.payload, now: uptime())
            judgeWorldLevelSnap()
            let wasTT180 = stickMapping.commanded180
            stickMapping.applyAttitude(frame.payload)
            syncPose()
            let attitude = GimbalStick.isAttitude(frame.payload)
            if attitude {
                lastNativeWaypoint = GimbalWaypoint.from(
                    yawTenth: GimbalStick.yawTenthDeg(frame.payload),
                    pitchTenth: GimbalStick.pitchTenthDeg(frame.payload), zoom: host.zoomReadout,
                    nativePitchTenth: GimbalStick.nativePitchTenthDeg(frame.payload))
            }
            if attitude, let pose = liveWaypoint {
                let now = uptime()
                overlayMotion.observe(pose, at: now)
                if let previous = lastMoveObservedPose, let receivedAt = lastMoveAttitudeAt,
                    now - receivedAt <= 0.3,
                    GimbalMoveEngine.angularDistance(previous, pose) <= 0.100001
                {
                    if movePoseStableSince == nil { movePoseStableSince = now }
                } else {
                    movePoseStableSince = now
                    lastMoveObservedPose = pose
                }
                if stickHeld { movePoseStableSince = nil }
                lastMoveAttitudeAt = now
                restorePrep(prep.restore(busy: nativeHeadToken != nil || host.gimbalMoveRunning, now: now))
            }
            tickLimit()
            if stickMapping.commanded180 != wasTT180 {
                host.gimbalLog(
                    "control: gimbal TT180=\(stickMapping.commanded180 ? 1 : 0) yaw=\(stickMapping.yawTenthDeg.map { String($0) } ?? "-") seed=\(stickMapping.poseSeeded ? 1 : 0) view=\(host.gimbalPoseViewFlip ? 1 : 0)"
                )
            }
        }
        if frame.cmdId == 0x27 {
            let previousFace = stickMapping.face
            let body = stickMapping.noteBodyFace(s.gimbalFace)
            syncPose()
            let m = stickMapping
            if body {
                host.gimbalLog(
                    "control: gimbal body TT180 invert=\(m.invertPan ? 1 : 0) rot180=\(m.rotated180 ? 1 : 0) view=\(m.poseViewFlip ? 1 : 0) pend=\(m.pendingRotateCount)"
                )
            } else if let new = m.face, previousFace != new {
                host.gimbalLog(
                    "control: gimbal face=\(new == .selfie ? "selfie" : "front") invert=\(m.invertPan ? 1 : 0) rot180=\(m.rotated180 ? 1 : 0) view=\(m.poseViewFlip ? 1 : 0) parity=\(m.rotateParity ? 1 : 0)"
                )
            }
        }
    }

    /// After the host applied the report: a recording stop ends a take, and the `0x04/0x50`
    /// GET reply reconciles mode and speed against their pins.
    public func settle(_ frame: Duml.Frame, status s: CameraStatus) {
        guard let host else { return }
        if wasRecording && !s.isRecording {
            cancelProgrammedMove()
        }
        wasRecording = s.isRecording
        guard frame.cmdSet == 0x04, frame.cmdId == 0x50,
            let params = GimbalParamState.parseGetReply(frame.payload)
        else { return }
        let resolved = GimbalControl.modeFromGet(params, commanded: host.gimbalMode)
        let reportedMode: GimbalMode? =
            followFamilyConfirmed && (host.gimbalMode == .follow || host.gimbalMode == .tiltLocked)
            ? resolved : nil
        let mode =
            CameraValuePin.reconcile(
                &modePin, reported: reportedMode, now: wall().timeIntervalSinceReferenceDate)
            ?? resolved
        if mode != host.gimbalMode { host.gimbalMode = mode }
        if let speed = params.speed {
            let reconciled =
                CameraValuePin.reconcile(
                    &speedPin, reported: speed, now: wall().timeIntervalSinceReferenceDate)
                ?? speed
            if reconciled != host.gimbalSpeed { host.gimbalSpeed = reconciled }
        }
    }

    /// Our own pan must never read as a reconnect-at-180 seed.
    private func noteAppMotion() {
        guard !stickMapping.poseSeeded else { return }
        stickMapping.noteAppMotion()
        if stickMapping.poseSeeded {
            host?.gimbalLog(
                "control: gimbal seed front by app motion yaw=\(stickMapping.yawTenthDeg.map { String($0) } ?? "-")"
            )
        }
    }

    private func tickLimit() {
        guard let host else { return }
        let pulse = limitWatch.tick(
            x: lastCommand.x,
            y: lastCommand.y,
            yawTenthDeg: stickMapping.yawTenthDeg,
            pitchTenthDeg: stickMapping.pitchTenthDeg,
            now: wall().timeIntervalSinceReferenceDate,
            settling180: !stickMapping.pendingWant180.isEmpty)
        guard !pulse.isEmpty else { return }
        host.gimbalLimitContact = pulse
        host.gimbalLimitPanSign = limitWatch.lastPanSign
        host.gimbalLimitTiltSign = limitWatch.lastTiltSign
        host.gimbalLimitPulse += 1
    }
}

#if os(iOS)
    extension DjiAppleDatalink: DjiAppleGimbalLink {}
#endif
