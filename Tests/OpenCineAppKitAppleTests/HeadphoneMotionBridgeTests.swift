#if os(iOS)
import CoreMotion
import OpenCineAppKitApple
import OpenCineMotion
import XCTest
import os

@MainActor
final class HeadphoneMotionBridgeTests: XCTestCase {
    func testPermissionPendingRepeatedSyncKeepsTheFirstStartAndItsCallback() async {
        let motion = PendingHeadphoneMotionManager()
        var auth = CMAuthorizationStatus.notDetermined
        let bridge = makeBridge(
            motion: motion, authorizationStatus: { auth }, uptime: { 100 })
        let host = FakeHeadTrackHost()
        host.headTrackingEnabled = true
        bridge.attach(host: host)
        defer { bridge.detach() }
        bridge.sync()
        bridge.headphoneMotionManagerDidConnect(motion)
        // The delegate hops onto MainActor, where it calls startMotion then sync.
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(motion.starts.count, 1, "Pending permission must have one owned start")

        auth = .authorized
        motion.active = true
        bridge.sync()
        // Deliberately retain the first handler: duplicate-start handler ownership
        // is undocumented by Core Motion and must not be needed for correctness.
        motion.starts.first?(HeadphoneMotionSample(timestamp: 99.95), nil)
        XCTAssertEqual(
            bridge.receivedHeadSampleAt, 99.95, "Permission approval must not need an off/on toggle"
        )
    }

    /// OPENPOCKETCINE-IOS-3N: Core Motion calls the handler on the request's queue, so a handler
    /// that inherited the bridge's main-actor isolation trapped when head tracking started.
    func testCoreMotionDeliversSamplesOnTheMotionQueue() async {
        let motion = PendingHeadphoneMotionManager()
        let bridge = makeBridge(
            motion: motion, authorizationStatus: { .authorized }, uptime: { 100 })
        let host = FakeHeadTrackHost()
        host.headTrackingEnabled = true
        bridge.attach(host: host)
        defer { bridge.detach() }
        guard let queue = motion.queues.first, let start = motion.starts.first else {
            return XCTFail("Head tracking did not request motion")
        }
        nonisolated(unsafe) let handler = start
        let delivered = expectation(description: "Sample delivered on the motion queue")
        queue.addOperation {
            XCTAssertFalse(Thread.isMainThread)
            handler(HeadphoneMotionSample(timestamp: 99.95), nil)
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 1)
        XCTAssertEqual(bridge.receivedHeadSampleAt, 99.95)
    }

    func testStoppingPendingPermissionCancelsTheRequestAndFencesItsCallback() {
        let motion = PendingHeadphoneMotionManager()
        let bridge = makeBridge(
            motion: motion, authorizationStatus: { .notDetermined }, uptime: { 100 })
        let host = FakeHeadTrackHost()
        host.headTrackingEnabled = true
        bridge.attach(host: host)
        defer { bridge.detach() }
        let initialStops = motion.stopCount
        let oldCallback = motion.starts.first
        host.headTrackingEnabled = false
        bridge.sync()
        XCTAssertEqual(
            motion.stopCount, initialStops + 1,
            "An inactive OS stream can still have a pending start")
        oldCallback?(HeadphoneMotionSample(timestamp: 99.95), nil)
        XCTAssertNil(bridge.receivedHeadSampleAt)

        host.headTrackingEnabled = true
        bridge.sync()
        motion.starts.last?(HeadphoneMotionSample(timestamp: 99.96), nil)
        XCTAssertEqual(bridge.receivedHeadSampleAt, 99.96)
        oldCallback?(HeadphoneMotionSample(timestamp: 99.97), nil)
        XCTAssertEqual(
            bridge.receivedHeadSampleAt, 99.96, "Prior callback cannot replace the new stream")
    }

    func testPermissionDeniedTapPreservesPermissionGuidance() {
        let motion = PendingHeadphoneMotionManager()
        let bridge = makeBridge(motion: motion, authorizationStatus: { .denied })
        let host = FakeHeadTrackHost()
        host.headTrackingEnabled = true
        bridge.attach(host: host)
        defer { bridge.detach() }
        bridge.tapControl()
        XCTAssertEqual(
            host.controlNote, "Allow Motion & Fitness for TestApp in Settings")
        XCTAssertTrue(motion.starts.isEmpty)
    }

    func testMotionFailureStopsTheStreamAndRequiresAnExplicitRetry() async {
        let motion = PendingHeadphoneMotionManager()
        let bridge = makeBridge(
            motion: motion, authorizationStatus: { .authorized }, uptime: { 100 })
        let host = FakeHeadTrackHost()
        host.headTrackingEnabled = true
        bridge.attach(host: host)
        defer { bridge.detach() }
        let stopped = expectation(description: "Failed motion request cancelled")
        motion.onStop = { stopped.fulfill() }
        let failedCallback = motion.starts.first
        failedCallback?(nil, NSError(domain: "HeadphoneMotionTest", code: 1))
        await fulfillment(of: [stopped], timeout: 1)
        motion.onStop = nil
        bridge.sync()
        XCTAssertEqual(motion.starts.count, 1, "Ordinary sync must not retry an error indefinitely")
        XCTAssertEqual(
            host.controlNote, "Headphone motion stopped. Tap Calibrate to retry")
        bridge.tapControl()
        XCTAssertEqual(motion.starts.count, 2)
        motion.starts.last?(HeadphoneMotionSample(timestamp: 99.95), nil)
        failedCallback?(HeadphoneMotionSample(timestamp: 99.97), nil)
        XCTAssertEqual(bridge.receivedHeadSampleAt, 99.95)
    }

    func testExplicitRetryAfterNoSamplesDoesNotRestartPendingPermission() {
        let motion = PendingHeadphoneMotionManager()
        let clock = OSAllocatedUnfairLock(initialState: 100.0)
        var auth = CMAuthorizationStatus.notDetermined
        let bridge = makeBridge(
            motion: motion, authorizationStatus: { auth }, uptime: { clock.withLock { $0 } })
        let host = FakeHeadTrackHost()
        host.headTrackingEnabled = true
        bridge.attach(host: host)
        defer { bridge.detach() }
        clock.withLock { $0 = 110 }
        bridge.tapControl()
        XCTAssertEqual(motion.starts.count, 1)
        XCTAssertEqual(host.controlNote, "Allow Motion & Fitness to start head tracking")

        auth = .authorized
        motion.active = true
        bridge.tapControl()
        XCTAssertEqual(
            motion.starts.count, 2, "An explicit tap can replace a silent authorized stream")
        XCTAssertEqual(host.controlNote, "Waiting for headphone motion")
        motion.starts.last?(HeadphoneMotionSample(timestamp: 109.95), nil)
        XCTAssertEqual(bridge.receivedHeadSampleAt, 109.95)
    }

    /// OpenPocketCine#638: head tracking in FPV jumped the gimbal on its first targets. When the
    /// host reports a lasting stop, Calibrate shows its note and never starts the gimbal.
    func testCalibrateWithAHostStopShowsTheNoteAndNeverDrives() async throws {
        let (bridge, motion, host) = try await calibratableBridge()
        defer { bridge.detach() }
        host.headTrackStop = HeadTrackStop(reason: "mode=FPV", note: "Not in this mode")
        bridge.tapControl()
        XCTAssertEqual(host.controlNote, "Not in this mode")
        XCTAssertEqual(host.begins, 0)
        XCTAssertEqual(host.headTrackControlTitle, HeadphoneMotionBridge.calibrateTitle)
        await deliver(motion, at: 99.96)
        XCTAssertEqual(host.begins, 0, "A refused calibration does not retry on every sample")

        host.headTrackStop = nil
        bridge.tapControl()
        XCTAssertEqual(host.controlNote, "Head lock set. Gimbal follows")
        XCTAssertEqual(host.begins, 1)
        XCTAssertEqual(host.headTrackControlTitle, HeadphoneMotionBridge.stopTitle)
    }

    /// OpenPocketCine#638: past the reach every target was refused and the bridge re-armed the
    /// gimbal about 10 times a second with no message. A host stop ends tracking once instead.
    func testAHostStopWhileDrivingEndsTrackingOnceWithItsNote() async throws {
        let (bridge, motion, host) = try await calibratableBridge()
        defer { bridge.detach() }
        bridge.tapControl()
        XCTAssertEqual(host.begins, 1)
        host.headTrackStop = HeadTrackStop(reason: "pastReach", note: "Past the range")
        bridge.sync()
        XCTAssertEqual(host.controlNote, "Past the range")
        XCTAssertEqual(host.ends, [1])
        XCTAssertEqual(host.headTrackControlTitle, HeadphoneMotionBridge.calibrateTitle)
        XCTAssertTrue(host.log.contains("head-track: stopped reason=pastReach"), "\(host.log)")
        for _ in 0..<5 { bridge.sync() }
        await deliver(motion, at: 99.96)
        XCTAssertEqual(host.begins, 1, "No re-arm after the stop")
        XCTAssertEqual(host.ends, [1])
    }

    /// The refusal can come from the update itself, between two host checks.
    func testARefusedUpdateWithAHostStopEndsTrackingInsteadOfRearming() async throws {
        let (bridge, _, host) = try await calibratableBridge()
        defer { bridge.detach() }
        bridge.tapControl()
        host.onUpdate = { host.headTrackStop = HeadTrackStop(reason: "pastReach", note: "Past the range") }
        host.updateResult = false
        bridge.sync()
        XCTAssertEqual(host.controlNote, "Past the range")
        bridge.sync()
        XCTAssertEqual(host.begins, 1)
    }

    func testStartupDiagnosticsAreBoundedAndDistinguishAcceptedFromRejectedSamples() {
        let motion = PendingHeadphoneMotionManager()
        let clock = OSAllocatedUnfairLock(initialState: 100.0)
        var lines: [String] = []
        let bridge = makeBridge(
            motion: motion, authorizationStatus: { .authorized }, uptime: { clock.withLock { $0 } },
            startupLog: { lines.append($0) })
        let host = FakeHeadTrackHost()
        host.headTrackingEnabled = true
        bridge.attach(host: host)
        defer { bridge.detach() }
        for _ in 0..<20 { bridge.sync() }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("requested=1"))
        XCTAssertTrue(
            lines[0].contains(
                "accepted=0 rejected=0 stale=0 future=0 other=0 lastRejectAgeMs=- sampleAgeMs=-"))

        motion.starts.first?(HeadphoneMotionSample(timestamp: 99.95), nil)
        motion.starts.first?(HeadphoneMotionSample(timestamp: 99.95), nil)
        motion.starts.first?(HeadphoneMotionSample(timestamp: 100.5), nil)
        motion.starts.first?(HeadphoneMotionSample(timestamp: 99), nil)
        clock.withLock { $0 = 101 }
        bridge.sync()
        XCTAssertEqual(lines.count, 2)
        // Duplicate = other, clock-base mismatch = future, late = stale.
        XCTAssertTrue(
            lines[1].contains(
                "accepted=1 rejected=3 stale=1 future=1 other=1 lastRejectAgeMs=1000 sampleAgeMs=1050"),
            lines[1])
        XCTAssertEqual(motion.starts.count, 1)
    }
}

@MainActor
private func deliver(_ motion: PendingHeadphoneMotionManager, at timestamp: TimeInterval) async {
    motion.starts.last?(HeadphoneMotionSample(timestamp: timestamp), nil)
    // The sample pump pulls every `sampleInterval` (40 ms).
    try? await Task.sleep(for: .milliseconds(150))
}

/// A bridge with a live, drivable host and a fresh head sample, ready for Calibrate.
@MainActor
private func calibratableBridge() async throws
    -> (HeadphoneMotionBridge, PendingHeadphoneMotionManager, FakeHeadTrackHost)
{
    let motion = PendingHeadphoneMotionManager()
    let host = FakeHeadTrackHost()
    let bridge = HeadphoneMotionBridge(
        appName: "TestApp", bounds: MotionBounds(pan: -48...225, tilt: -44...70), sampleInterval: 0.04,
        hudInterval: 0.2, log: { [weak host] in host?.log.append($0) }, motion: motion,
        authorizationStatus: { .authorized }, uptime: { 100 })
    host.headTrackingEnabled = true
    host.headTrackCanDrive = true
    host.freshGimbalWaypoint = GimbalWaypoint(yawDeg: 0, pitchDeg: 5.6, zoom: 1, nativePitchDeg: 174.4)
    bridge.attach(host: host)
    await deliver(motion, at: 99.95)
    XCTAssertEqual(bridge.receivedHeadSampleAt, 99.95)
    return (bridge, motion, host)
}

@MainActor
private func makeBridge(
    motion: CMHeadphoneMotionManager,
    authorizationStatus: @escaping () -> CMAuthorizationStatus,
    uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    startupLog: ((String) -> Void)? = nil
) -> HeadphoneMotionBridge {
    HeadphoneMotionBridge(
        appName: "TestApp", bounds: MotionBounds(pan: -48...225, tilt: -44...70), sampleInterval: 0.04, hudInterval: 0.2, log: { _ in }, motion: motion,
        authorizationStatus: authorizationStatus, uptime: uptime, startupLog: startupLog)
}

@MainActor
private final class FakeHeadTrackHost: HeadTrackHost {
    var headTrackingEnabled = false
    var hapticsEnabled = false
    var gimbalAnalogHeld = false
    var headTrackCanDrive = false
    var isLiveVideoStale = false
    var controlNote: String?
    var headTrackControlTitle = HeadphoneMotionBridge.calibrateTitle
    var headTrackImuReadout = ""
    var headTrackAxisPose: HeadTrackAxisPose?
    var freshGimbalWaypoint: GimbalWaypoint?
    var gimbalYawTenthDeg: Int16?
    var gimbalPitchTenthDeg: Int16?
    var gimbalAttitudeHex = ""
    var gimbalAttitudeDump = ""
    var headTrackStop: HeadTrackStop?
    var begins = 0
    var ends: [UInt64] = []
    var updateResult = true
    var onUpdate: (() -> Void)?
    var log: [String] = []
    func beginNativeHeadTrack() -> UInt64? {
        guard headTrackCanDrive, headTrackStop == nil else { return nil }
        begins += 1
        return UInt64(begins)
    }
    func updateNativeHeadTrack(target: GimbalWaypoint, token: UInt64, measuredAt: TimeInterval?) -> Bool {
        onUpdate?()
        return updateResult
    }
    func endNativeHeadTrack(token: UInt64) { ends.append(token) }
}

private final class PendingHeadphoneMotionManager: CMHeadphoneMotionManager {
    var active = false
    var connectionActive = false
    var starts: [CMHeadphoneMotionManager.DeviceMotionHandler] = []
    var queues: [OperationQueue] = []
    var stopCount = 0
    var onStop: (() -> Void)?
    override var isDeviceMotionAvailable: Bool { true }
    override var isDeviceMotionActive: Bool { active }
    override var isConnectionStatusActive: Bool { connectionActive }
    override func startConnectionStatusUpdates() { connectionActive = true }
    override func stopConnectionStatusUpdates() { connectionActive = false }
    override func startDeviceMotionUpdates(
        to queue: OperationQueue,
        withHandler handler: @escaping CMHeadphoneMotionManager.DeviceMotionHandler
    ) {
        starts.append(handler)
        queues.append(queue)
    }
    override func stopDeviceMotionUpdates() {
        stopCount += 1
        active = false
        onStop?()
    }
}

private final class HeadphoneMotionSample: CMDeviceMotion {
    private let measuredAt: TimeInterval
    init(timestamp: TimeInterval) {
        measuredAt = timestamp
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override var timestamp: TimeInterval { measuredAt }
    override var attitude: CMAttitude { IdentityHeadphoneAttitude() }
    override var rotationRate: CMRotationRate { CMRotationRate(x: 0, y: 0, z: 0) }
}

private final class IdentityHeadphoneAttitude: CMAttitude {
    override var quaternion: CMQuaternion { CMQuaternion(x: 0, y: 0, z: 0, w: 1) }
    override var yaw: Double { 0 }
    override var pitch: Double { 0 }
    override var roll: Double { 0 }
}
#endif
