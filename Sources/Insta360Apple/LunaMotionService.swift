import Foundation
import Insta360Protocol
import OpenCineCore
import OpenCineMotion

/// The Luna gimbal (cmd 226) on the session's control path: the held stick as a MOVE stream,
/// single steering MOVEs, release, recenter, flip, SET_ANGLE and GET_ANGLE, with the shared
/// `MotionService` over them. Steering loops (aim until arrival, head tracking, programmed moves)
/// stay with the app until their value types leave the DJI-shaped app core.
@MainActor public final class LunaMotionService: MotionService {
    /// Official app range: sint32 ±99 on each VirtualRC axis.
    public nonisolated static let stickFullScale = 99.0
    /// A held stick repeats MOVE at this period.
    public nonisolated static let stickInterval: Duration = .milliseconds(50)
    /// `poses()` reads GET_ANGLE at this period.
    public nonisolated static let poseInterval: Duration = .milliseconds(100)
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
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
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
        self.pan = Int32((pan * Self.stickFullScale).rounded())
        self.tilt = Int32((tilt * Self.stickFullScale).rounded())
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

    private func send(_ request: LunaRequest?, timeout: Duration?) async -> Bool {
        guard let request, let session = session() else { return false }
        return (try? await session.control(request, timeout: timeout)) != nil
    }
}
