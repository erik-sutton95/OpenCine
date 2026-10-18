import Foundation
import Insta360Protocol
import OpenCineCore
import OpenCineMotion

/// The Luna gimbal (cmd 226) on the session's control path: the held stick as a MOVE stream,
/// single steering MOVEs, release, recenter, flip, SET_ANGLE and GET_ANGLE, with the shared
/// `MotionService` over them. Shared `MotionProgramSession` runs programmed targets; the app's
/// steering and head-tracking adapters use `hasReached`, `LunaHeadTrackSteering` and
/// `HeadTrack.reference` against their live state.
@MainActor public final class LunaMotionService: MotionService {
    /// Official app range: sint32 ±99 on each VirtualRC axis.
    public nonisolated static let stickFullScale = 99.0
    /// A held stick repeats MOVE at this period.
    public nonisolated static let stickInterval: Duration = .milliseconds(50)
    /// `poses()` reads GET_ANGLE at this period.
    public nonisolated static let poseInterval: Duration = .milliseconds(100)
    /// Existing approach countdown and SET_ANGLE cadence for the shared streamed take owner.
    public nonisolated static let programTiming = MotionProgramTiming(
        countdown: .seconds(3), targetInterval: .milliseconds(33))
    /// MOVE and SET_ANGLE wait at most this long for the camera's reply.
    nonisolated static let moveTimeout: Duration = .seconds(2)

    public nonisolated var capabilities: MotionCapabilities { LunaCameraSession.motion }
    public private(set) var isHeld = false
    /// The newest GET_ANGLE as a pose, `.unknown` until the camera answers one.
    public private(set) var latestPose: ObservedValue<GimbalWaypoint> = .unknown
    private var pan: Int32 = 0
    private var tilt: Int32 = 0
    private var stream: Task<Void, Never>?
    private let session: @MainActor () -> LunaCameraSession?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> MonotonicInstant

    /// `session` is the connection's current session; tests inject `sleep` and `now`.
    public init(
        session: @escaping @MainActor () -> LunaCameraSession?,
        sleep: @escaping @Sendable (Duration) async throws -> Void = hostSleep(for:),
        now: @escaping @Sendable () -> MonotonicInstant = MonotonicInstant.now
    ) {
        self.session = session
        self.sleep = sleep
        self.now = now
    }

    /// Holds the stick at each axis -1...1 of full speed (rounded to the wire's ±99) and repeats
    /// MOVE every `stickInterval` until `endHold()`. A held stick at 0, 0 keeps repeating: on Luna
    /// MOVE 0, 0 is the release request itself.
    public func hold(pan: Double, tilt: Double) {
        self.pan = Self.wireSpeed(pan)
        self.tilt = Self.wireSpeed(tilt)
        guard !isHeld else { return }
        isHeld = true
        stream?.cancel()
        stream = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isHeld else { return }
                await self.steer(pan: self.pan, tilt: self.tilt)
                try? await self.sleep(Self.stickInterval)
            }
        }
    }

    /// One axis in wire units. A deflection the caller kept (non-zero) never rounds to 0: on Luna
    /// MOVE 0 on both axes is the release request, so a slow deflection that rounded to 0 stopped
    /// the head mid-move (OPENINSTACINE-IOS-3, gamepad at low sensitivity).
    nonisolated public static func wireSpeed(_ axis: Double) -> Int32 {
        let clamped = max(-1, min(1, axis))
        let rounded = Int32((clamped * stickFullScale).rounded())
        if rounded == 0, clamped != 0 { return clamped > 0 ? 1 : -1 }
        return rounded
    }

    /// Stops repeating MOVE; the caller sends `release()` when it wants the head at rest.
    public func endHold() {
        isHeld = false
        stream?.cancel()
        stream = nil
        pan = 0
        tilt = 0
    }

    /// One MOVE in wire units (±99 per axis), as head tracking steers.
    @discardableResult
    public func steer(pan: Int32, tilt: Int32) async -> Bool {
        await send(
            try? LunaProtocol.gimbalMove(upDown: tilt, leftRight: pan), timeout: Self.moveTimeout)
    }

    /// VirtualRC rest, with the backend's own timeout.
    @discardableResult
    public func release() async -> Bool {
        await send(try? LunaProtocol.gimbalReleaseRequest(), timeout: nil)
    }

    @discardableResult
    public func recenter() async -> Bool {
        await send(try? LunaProtocol.gimbalRecenterRequest(), timeout: nil)
    }

    @discardableResult
    public func flip() async -> Bool {
        await send(try? LunaProtocol.gimbalFlipRequest(), timeout: nil)
    }

    /// SET_ANGLE at `pose` (handle frame): yaw back to ±180, pitch kept inside the declared reach.
    /// The camera re-targets on every SET (latest wins).
    @discardableResult
    public func aim(at pose: GimbalWaypoint) async -> Bool {
        let tilt = capabilities.bounds.tilt
        let pitch = min(max(pose.pitchDeg, tilt.lowerBound), tilt.upperBound)
        return await send(
            try? LunaProtocol.gimbalSetAngle(
                pitch: Float(pitch), yaw: Float(remainder(pose.yawDeg, 360))),
            timeout: Self.moveTimeout)
    }

    /// GET_ANGLE; also updates `latestPose`.
    @discardableResult
    public func readAngle(timeout: Duration = .seconds(1)) async -> LunaGimbalAngle? {
        guard let request = try? LunaProtocol.gimbalGetAngleRequest(), let session = session(),
            let reply = try? await session.control(request, timeout: timeout),
            let angle = try? LunaGimbalAngle(response: reply)
        else { return nil }
        let pitch = Double(angle.pitch)
        // Luna moves carry no zoom (`capabilities` declares none): a pose keeps the neutral 1.
        latestPose = ObservedValue(
            GimbalWaypoint(
                yawDeg: GimbalWaypoint.unwrapYaw(Double(angle.yaw), in: capabilities.bounds),
                pitchDeg: pitch, zoom: 1, nativePitchDeg: -pitch),
            origin: .cameraReported, at: now())
        return angle
    }

    // MARK: - MotionService

    public func stick(pan: Double, tilt: Double) async -> Bool {
        guard pan != 0 || tilt != 0 else { return await stop() }
        hold(pan: pan, tilt: tilt)
        return session()?.admitsControl == true
    }

    /// Luna plans each SET_ANGLE as its own move, so only `duration == nil` is accepted; a timed
    /// move is the caller's stream of targets.
    public func move(to target: MotionTarget, over duration: Duration?) async -> Bool {
        guard duration == nil else { return false }
        return await aim(at: target.pose)
    }

    public func stop() async -> Bool {
        endHold()
        return await release()
    }

    public func poses() async -> AsyncStream<ObservedValue<GimbalWaypoint>> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: ObservedValue<GimbalWaypoint>.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(latestPose)
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                if await self.readAngle() != nil { continuation.yield(self.latestPose) }
                try? await self.sleep(Self.poseInterval)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in poll.cancel() }
        return stream
    }

    /// GET_ANGLE within the arrival tolerance of `target` on each axis, yaw across ±180.
    public nonisolated static func hasReached(_ angle: LunaGimbalAngle, _ target: GimbalWaypoint) -> Bool {
        let tolerance = LunaCameraSession.motion.arrivalToleranceDeg
        return abs(remainder(Double(angle.yaw) - target.yawDeg, 360)) <= tolerance
            && abs(Double(angle.pitch) - target.pitchDeg) <= tolerance
    }

    private func send(_ request: LunaRequest?, timeout: Duration?) async -> Bool {
        guard let request, let session = session() else { return false }
        return (try? await session.control(request, timeout: timeout)) != nil
    }
}

/// Head tracking steers with the stick (MOVE), not SET_ANGLE: fw 1.1.15 re-plans every SET as its
/// own start-stop move, so a SET stream judders at the send rate (about 11 deg/s rms at 30 Hz
/// against 0.05 for the stick). Each tick commands the head's own rate plus a pull toward its
/// exact angle, from GET_ANGLE carried forward by a model of the rate the sent sticks give.
public struct LunaHeadTrackSteering: Sendable {
    /// Live-tunable feel. Defaults are fw 1.1.15's.
    public struct Tuning: Equatable, Sendable {
        /// Stick rate per VirtualRC unit. The gyro reads 0.635 and 0.54 deg/s per unit at steady
        /// speed; these are what tracked a 20° sine best against GET_ANGLE (lag 0.02 s, 8%
        /// overshoot).
        public var panDegPerSec: Double
        public var tiltDegPerSec: Double
        /// Pull toward the head's exact angle (1/s).
        public var gain: Double
        /// Share of the stick's ease-in lag the head's acceleration is fed forward over.
        public var accelFeed: Double

        public init(panDegPerSec: Double = 0.75, tiltDegPerSec: Double = 0.64, gain: Double = 4, accelFeed: Double = 1) {
            self.panDegPerSec = panDegPerSec
            self.tiltDegPerSec = tiltDegPerSec
            self.gain = gain
            self.accelFeed = accelFeed
        }
    }

    /// One tick: the stick to send and the angles it steers between.
    public struct Step: Equatable, Sendable {
        public var pan: Int32
        public var tilt: Int32
        /// GET_ANGLE carried forward to now (yaw unwrapped as read).
        public var yaw: Double
        public var pitch: Double
        /// The head's pitch inside the Luna's tilt reach.
        public var wantPitch: Double
    }

    /// The stick's ease-in lag, fw 1.1.15.
    public static let stickLagSeconds = 0.23
    /// GET_ANGLE round trip is 20 to 40 ms on the camera AP; half of it, roughly.
    public static let angleReadLatency = 0.015

    private var yawRate = 0.0
    private var pitchRate = 0.0
    private var last: TimeInterval

    /// `now` is uptime seconds, the clock of every later call.
    public init(now: TimeInterval) { last = now }

    /// The stick toward `head` from a GET_ANGLE read at `readAt`. The reading was taken about
    /// half a round trip before it arrived; the head has kept turning since.
    public func step(
        yaw: Double, pitch: Double, readAt: TimeInterval, toward head: HeadTrack.Reference,
        now: TimeInterval, tuning: Tuning
    ) -> Step {
        let age = now - readAt + Self.angleReadLatency
        let yaw = yaw + yawRate * age
        let pitch = pitch + pitchRate * age
        let reach = LunaCameraSession.motion.bounds.tilt
        let wantPitch = min(max(head.pitch, reach.lowerBound), reach.upperBound)
        // Feed the head's rate forward, plus its acceleration times the stick's ease-in lag so
        // the camera speeds up in step with the head instead of trailing it.
        let lag = Self.stickLagSeconds * tuning.accelFeed
        let yawRate = head.yawRate + head.yawAccel * lag + tuning.gain * (head.yaw - yaw)
        let pitchRate = head.pitchRate + head.pitchAccel * lag + tuning.gain * (wantPitch - pitch)
        let full = LunaMotionService.stickFullScale
        return Step(
            pan: Int32(min(max((yawRate / tuning.panDegPerSec).rounded(), -full), full)),
            tilt: Int32(min(max((pitchRate / tuning.tiltDegPerSec).rounded(), -full), full)),
            yaw: yaw, pitch: pitch, wantPitch: wantPitch)
    }

    /// Records the stick just sent: the modelled camera rate eases toward it.
    public mutating func sent(pan: Int32, tilt: Int32, now: TimeInterval, tuning: Tuning) {
        let k = 1 - exp(-(now - last) / Self.stickLagSeconds)
        last = now
        yawRate += (Double(pan) * tuning.panDegPerSec - yawRate) * k
        pitchRate += (Double(tilt) * tuning.tiltDegPerSec - pitchRate) * k
    }
}
