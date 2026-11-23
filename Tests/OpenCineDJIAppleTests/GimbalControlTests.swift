import Foundation
import OpenCineDJI
import OpenCineDJIApple
import OpenCineMotion
import Testing

/// SIMULATED host and link; manual clocks and an immediate sleep. No camera is involved.
@Suite @MainActor
struct DJIAppleGimbalControlTests {
    @MainActor private final class Link: DjiAppleGimbalLink {
        var isClosed = false
        var sent: [Duml.Frame] = []
        var untracked: [Duml.Frame] = []
        var sticks: [UInt16] = []
        var rests = 0
        var targetTokens: [UInt64] = []
        var endedTokens: [UInt64] = []
        var programTokens: [UInt64] = []
        var canceledTokens: [UInt64] = []
        var nativeTargets: [Duml.Frame] = []
        func send(_ frame: Duml.Frame) -> UInt16 {
            sent.append(frame)
            return UInt16(sent.count)
        }
        func sendUntracked(_ frame: Duml.Frame) -> UInt16 {
            untracked.append(frame)
            return UInt16(untracked.count)
        }
        func noteGimbalStick(axis0: UInt16, axis1: UInt16) { sticks += [axis0, axis1] }
        func restGimbalStick() { rests += 1 }
        func beginNativeTargets(token: UInt64) { targetTokens.append(token) }
        func noteNativeTarget(_ frame: Duml.Frame, token: UInt64) -> Bool {
            nativeTargets.append(frame)
            return true
        }
        func endNativeTargets(token: UInt64) { endedTokens.append(token) }
        func startNativeProgram(
            program: GimbalProgram, token: UInt64, zoom: GimbalProgramZoom?,
            onProgress: @escaping @MainActor @Sendable (UInt64, GimbalMoveEngine, GimbalWaypoint) -> Void
        ) -> Bool {
            programTokens.append(token)
            return true
        }
        func pauseNativeProgram(token: UInt64) -> Bool { true }
        func resumeNativeProgram(token: UInt64) -> Bool { true }
        func cancelNativeProgram(token: UInt64) -> Bool {
            canceledTokens.append(token)
            return true
        }
    }

    @MainActor private final class Host: DjiAppleGimbalHost {
        let link = Link()
        var linked = true
        var gimbalLink: (any DjiAppleGimbalLink)? { linked ? link : nil }
        var hasGimbal = true
        var isLocked = false
        var isLivePhase = true
        var sessionRecovery = SessionRecoveryState.idle
        var gimbalControlSceneActive = true
        var isFeedWarming = false
        var holdsMonitor = false
        var isLiveVideoStale = false
        var isBrowsingMedia = false
        var zoomReadout = 1.0
        var status = CameraStatus()
        var cameraModel: CameraModel?
        var gimbalRamp = GimbalRamp.off
        var gimbalDoubleTap = GimbalDoubleTap.recenter
        var gimbalMode = GimbalMode.follow
        var gimbalSpeed = GimbalSpeed.defaultSpeed
        var gimbalProgram = GimbalProgram()
        /// Stands in for an observer of the published state, which runs before the write.
        var willChangeRunning: ((Bool) -> Void)?
        var gimbalMoveRunning = false { willSet { willChangeRunning?(newValue) } }
        var gimbalMovePaused = false
        var gimbalMoveCanPause = false
        var gimbalStartCountdown: Int?
        var gimbalPoseViewFlip = false
        var gimbalPoseInvertPan = false
        var gimbalLimitPulse: UInt = 0
        var gimbalLimitContact: GimbalLimitWatch.Contact = []
        var gimbalLimitPanSign = 0.0
        var gimbalLimitTiltSign = 0.0
        var controlNote: String?
        var log: [String] = []
        var syncedViewFlips: [Bool] = []
        var uptime: TimeInterval = 100
        var wall = Date(timeIntervalSinceReferenceDate: 1_000)
        var sleeps: [Duration] = []
        lazy var gimbal = DjiAppleGimbalControl(
            host: self, uptime: { [unowned self] in uptime }, wall: { [unowned self] in wall },
            sleep: { [unowned self] in
                sleeps.append($0)
                await Task.yield()
            })
        func gimbalLog(_ line: String) { log.append(line) }
        func gimbalPoseDidSync(viewFlip: Bool) { syncedViewFlips.append(viewFlip) }
        func retireZoomForProgrammedMove() -> Bool { true }

        /// A captured `0x04/0x05` push (2026-09-12 reliability logs).
        func attitude() {
            let hex = "0807000000008600000000020219CD05B3C5000000000200AA10D73532D7763F15BB873E1FB8B43600000000010000000000"
            let payload = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
                let start = hex.index(hex.startIndex, offsetBy: i)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }
            gimbal.ingest(frame(0x05, payload), status: status)
        }

        /// SYNTHETIC push: the captured frame above with native pitch `@0` and display pitch
        /// `-@20` set, cut to `count` bytes. 49 is the current Pocket 3 layout (OpenPocketCine#621).
        func attitude(nativeTenth: Int16, pitchTenth: Int16, count: Int) {
            let hex = "0807000000008600000000020219CD05B3C5000000000200AA10D73532D7763F15BB873E1FB8B43600000000010000000000"
            var payload = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
                let start = hex.index(hex.startIndex, offsetBy: i)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }
            for (value, offset) in [(nativeTenth, 0), (0 &- pitchTenth, 20)] {
                let bits = UInt16(bitPattern: value)
                payload[offset] = UInt8(bits & 0xFF)
                payload[offset + 1] = UInt8(bits >> 8)
            }
            ingestAttitude(Array(payload.prefix(count)))
        }

        /// SYNTHETIC push: the captured 50-byte frame with the mode family byte `@6` replaced
        /// (`0x46` FPV and `0x86` Follow as in the OpenPocketCine#638 export, `0x06` Direction Lock).
        func attitude(modeByte: UInt8) {
            let hex = "0807000000008600000000020219CD05B3C5000000000200AA10D73532D7763F15BB873E1FB8B43600000000010000000000"
            var payload = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
                let start = hex.index(hex.startIndex, offsetBy: i)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            }
            payload[6] = modeByte
            ingestAttitude(payload)
        }

        /// Projects the push into the status first, as the session does.
        func ingestAttitude(_ payload: [UInt8]) {
            if payload.count == 50 { status.gimbalModeFamily = GimbalModeFamily.parse(payload) }
            gimbal.ingest(frame(0x05, payload), status: status)
        }

        /// Head tracking setup frames (Fast, tilt unlocked) went out.
        var sentHeadTrackPrep: Bool {
            untrackedPayloads.contains(Commands.setGimbalSpeed(.fast).payload)
                || untrackedPayloads.contains(Commands.setGimbalTiltLock(.unlocked).payload)
        }

        var untrackedPayloads: [[UInt8]] { link.untracked.map(\.payload) }

        func frame(_ cmdId: UInt8, _ payload: [UInt8]) -> Duml.Frame {
            .init(sender: 0, receiver: 0, seq: 0, flags: 0, cmdSet: 0x04, cmdId: cmdId, payload: payload)
        }

        func paramReply(speed: GimbalSpeed) -> Duml.Frame {
            frame(0x50, [0x00, 0x01, 0x04, 0x01, 0x00, 0x05, 0x01, speed.rawValue])
        }
    }

    @Test func speedPinHoldsAgainstAnOlderReadbackUntilItsSettleWindowEnds() {
        let host = Host()
        host.gimbal.setSpeed(.fast)
        #expect(host.gimbalSpeed == .fast)
        #expect(host.link.untracked.map(\.payload) == [Commands.setGimbalSpeed(.fast).payload])
        host.wall += 1.9
        host.gimbal.settle(host.paramReply(speed: .defaultSpeed), status: host.status)
        #expect(host.gimbalSpeed == .fast)
        host.wall += 0.1
        host.gimbal.settle(host.paramReply(speed: .defaultSpeed), status: host.status)
        #expect(host.gimbalSpeed == .defaultSpeed)
    }

    @Test func disconnectResetClearsPinsSoTheNextReadbackWins() {
        let host = Host()
        host.gimbal.setSpeed(.slow)
        host.gimbal.setMode(.fpv)
        host.gimbal.resetControls()
        #expect(host.gimbalMode == .follow && host.gimbalSpeed == .defaultSpeed)
        host.gimbal.settle(host.paramReply(speed: .fast), status: host.status)
        #expect(host.gimbalSpeed == .fast)
    }

    @Test func configurationIsRefusedWhileWarmingHeldRecoveringStaleOrClosed() {
        let refusals: [(Host) -> Void] = [
            { $0.isFeedWarming = true }, { $0.holdsMonitor = true },
            { $0.sessionRecovery = .retrying(attempt: 1, maxAttempts: 8) },
            { $0.isLiveVideoStale = true }, { $0.link.isClosed = true }, { $0.linked = false },
            { $0.gimbalControlSceneActive = false }, { $0.isLocked = true }, { $0.isLivePhase = false },
        ]
        for refuse in refusals {
            let host = Host()
            refuse(host)
            host.gimbal.setMode(.fpv)
            host.gimbal.setSpeed(.fast)
            #expect(host.gimbalMode == .follow && host.gimbalSpeed == .defaultSpeed)
            #expect(host.link.untracked.isEmpty)
        }
    }

    @Test func stickStreamsThrowsAndRestsOnceWhenReleased() {
        let host = Host()
        host.gimbal.updateStick(x: 1, y: 0)
        host.gimbal.updateStick(x: 0.5, y: 0)
        #expect(host.link.sticks.count == 4 && host.gimbal.stickHeld)
        #expect(host.log.filter { $0.hasPrefix("control: gimbal stick stream") }.count == 1)
        #expect(host.gimbal.lastThrowAt == host.wall)
        host.gimbal.endStick()
        host.gimbal.endStick()
        #expect(host.link.rests == 1 && !host.gimbal.stickHeld)
    }

    @Test func stickOutsideAnAdmittedLiveSceneRestsInsteadOfStreaming() {
        let host = Host()
        host.gimbal.updateStick(x: 1, y: 0)
        host.gimbalControlSceneActive = false
        host.gimbal.updateStick(x: 1, y: 0)
        #expect(host.link.sticks.count == 2 && host.link.rests == 1)
        host.isLocked = true
        host.gimbal.updateStick(x: 1, y: 0)
        #expect(host.link.sticks.count == 2 && host.link.rests == 1)
    }

    @Test func headTrackNeedsFreshNativeFeedbackAndEndsOnlyItsOwnToken() throws {
        let host = Host()
        #expect(host.gimbal.beginNativeHeadTrack() == nil)
        host.attitude()
        let live = try #require(host.gimbal.freshWaypoint)
        let token = try #require(host.gimbal.beginNativeHeadTrack())
        #expect(host.link.targetTokens == [token])
        #expect(host.link.untracked.map(\.payload).contains(Commands.setGimbalSpeed(.fast).payload))
        #expect(host.gimbal.updateNativeHeadTrack(target: live, token: token))
        host.gimbal.endNativeHeadTrack(token: token &+ 1)
        #expect(host.link.endedTokens.isEmpty)
        host.uptime += 0.31
        #expect(host.gimbal.freshWaypoint == nil)
        #expect(!host.gimbal.updateNativeHeadTrack(target: live, token: token))
        #expect(host.link.endedTokens == [token])
    }

    @Test func programmedMoveCountsDownStartsNativeTakeAndCancelEndsIt() async throws {
        let host = Host()
        host.attitude()
        let live = try #require(host.gimbal.liveWaypoint)
        host.gimbalProgram.setPoint(.a, live)
        var b = live
        b.yawDeg += 20
        host.gimbalProgram.setPoint(.b, b.clamped())
        host.gimbal.runProgrammedMove()
        #expect(host.gimbalMoveRunning && host.gimbalStartCountdown == 3)
        for _ in 0..<50 where host.link.programTokens.isEmpty { await Task.yield() }
        #expect(host.sleeps == [.seconds(1), .seconds(1), .seconds(1), .milliseconds(250)])
        #expect(host.gimbalStartCountdown == nil && host.gimbalMoveCanPause)
        let token = try #require(host.link.programTokens.first)
        host.gimbal.cancelProgrammedMove()
        #expect(host.link.canceledTokens == [token])
        #expect(!host.gimbalMoveRunning && !host.gimbalMoveCanPause)
        #expect(!host.link.untracked.map(\.payload).contains(Commands.gimbalTimedStop().payload))
    }

    @Test func retiredCancelStopsAtTheFirstPublishedWriteAndKeepsSuccessorFacts() {
        let host = Host()
        host.gimbalMoveRunning = true
        var current = true
        host.willChangeRunning = { _ in
            current = false
            host.gimbalMoveCanPause = true
        }
        host.gimbal.cancelProgrammedMove(ifCurrent: { current })
        #expect(host.gimbalMoveCanPause)
        #expect(host.link.untracked.isEmpty)
        host.willChangeRunning = nil
        host.gimbalMoveRunning = true
        host.gimbal.cancelProgrammedMove()
        #expect(!host.gimbalMoveCanPause)
        #expect(host.link.untracked.map(\.payload) == [Commands.gimbalTimedStop().payload])
    }

    @Test func flipAndRecenterAreBodyMovesThatEndTheStickFirst() {
        let host = Host()
        host.gimbal.updateStick(x: 1, y: 0)
        host.gimbal.flip()
        #expect(host.link.rests == 1)
        #expect(host.link.sent.map(\.payload) == [Commands.gimbalFlip().payload])
        #expect(host.gimbal.stickMapping.pendingRotateCount == 1)
        host.gimbal.performDoubleTap()
        #expect(host.link.sent.map(\.payload).last == Commands.gimbalRecenter().payload)
        #expect(host.controlNote == "Gimbal re-centered")
    }

    /// OpenPocketCine#621: 49-byte attitude used to leave head tracking "waiting for gimbal",
    /// and once accepted a 9° look-down from native +174.4° went out as −176.6° (the long way).
    @Test func compactAttitudeFeedsHeadTrackingAndKeepsNativePitchOnTheCalibrationSide() throws {
        let host = Host()
        host.attitude(nativeTenth: 1744, pitchTenth: 56, count: 48)
        #expect(host.gimbal.freshWaypoint == nil, "an unknown layout is not feedback")
        host.attitude(nativeTenth: 1744, pitchTenth: 56, count: 49)
        let calibration = try #require(host.gimbal.freshWaypoint)
        #expect(calibration.nativePitchDeg == 174.4 && calibration.pitchDeg == 5.6)
        var track = HeadTrackNative()
        #expect(track.center(pose: calibration) == .centered)
        let token = try #require(host.gimbal.beginNativeHeadTrack())
        for lookUp in [-9.0, 5, 0] {
            let targetLook = track.target(lookRightDeg: 0, lookUpDeg: lookUp)
            let target = try #require(targetLook)
            #expect(host.gimbal.updateNativeHeadTrack(target: target, token: token))
        }
        // The gimbal crossed the wrap and reports −178.3°; the next look-down stays beside +174.4°.
        host.attitude(nativeTenth: -1783, pitchTenth: -21, count: 49)
        let downAgainLook = track.target(lookRightDeg: 0, lookUpDeg: -9)
        let downAgain = try #require(downAgainLook)
        #expect(host.gimbal.updateNativeHeadTrack(target: downAgain, token: token))
        let sent = host.link.nativeTargets.map { GimbalStick.i16LE($0.payload, at: 4) }
        #expect(sent == [1834, 1694, 1744, 1834])
        #expect(host.link.endedTokens.isEmpty)
    }

    /// The reporter's real 49-byte frames (`Fixtures/dji-attitude-pocket3-49.tsv`), by pose.
    static let captured: [String: [UInt8]] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Fixtures/dji-attitude-pocket3-49.tsv").path
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var frames: [String: [UInt8]] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t").map(String.init)
            guard f.count == 5 else { continue }
            let hex = Array(f[1])
            frames[f[0]] = stride(from: 0, to: hex.count, by: 2).compactMap {
                UInt8(String(hex[$0..<$0 + 2]), radix: 16)
            }
        }
        return frames
    }()

    /// Real capture: calibrated near level at native −176.9°, the look-up pose reads +171.9°.
    /// Head tracking keeps the target below −180° and Level keeps the tilted-down goal at −180.0°.
    @Test func capturedCompactFramesTrackAndLevelOnTheReferenceSide() throws {
        let level = try #require(Self.captured["level"]), up = try #require(Self.captured["up"])
        let down = try #require(Self.captured["down"])
        let host = Host()
        host.gimbal.ingest(host.frame(0x05, level), status: host.status)
        let calibration = try #require(host.gimbal.freshWaypoint)
        #expect(calibration.nativePitchDeg == -176.9 && calibration.pitchDeg == -0.7)
        var track = HeadTrackNative()
        #expect(track.center(pose: calibration) == .centered)
        let token = try #require(host.gimbal.beginNativeHeadTrack())
        host.gimbal.ingest(host.frame(0x05, up), status: host.status)
        let upLook = track.target(lookRightDeg: 0, lookUpDeg: 10.7)
        let upTarget = try #require(upLook)
        #expect(host.gimbal.updateNativeHeadTrack(target: upTarget, token: token))
        #expect(host.link.nativeTargets.map { GimbalStick.i16LE($0.payload, at: 4) } == [-1876])
        host.gimbal.endNativeHeadTrack(token: token)

        let leveler = Host()
        leveler.gimbalDoubleTap = .level
        leveler.gimbal.ingest(leveler.frame(0x05, down), status: leveler.status)
        leveler.gimbal.performDoubleTap()
        let sent = try #require(leveler.link.sent.last { $0.cmdId == 0x14 })
        #expect(GimbalStick.i16LE(sent.payload, at: 4) == -1800, "not +180.0° on the far side")
    }

    @Test func fullAttitudeHeadTrackSendsTheWrappedNativePitchAsBefore() throws {
        let host = Host()
        host.attitude(nativeTenth: 1744, pitchTenth: 56, count: 50)
        let calibration = try #require(host.gimbal.freshWaypoint)
        var track = HeadTrackNative()
        #expect(track.center(pose: calibration) == .centered)
        let token = try #require(host.gimbal.beginNativeHeadTrack())
        for lookUp in [-9.0, 5, 0] {
            let targetLook = track.target(lookRightDeg: 0, lookUpDeg: lookUp)
            let target = try #require(targetLook)
            #expect(host.gimbal.updateNativeHeadTrack(target: target, token: token))
        }
        let sent = host.link.nativeTargets.map { GimbalStick.i16LE($0.payload, at: 4) }
        #expect(sent == [-1766, 1694, 1744])
    }

    @Test func compactHeadTrackStopsWhenTheGimbalIsFarFromTheTarget() throws {
        let host = Host()
        host.attitude(nativeTenth: 1744, pitchTenth: 56, count: 49)
        let calibration = try #require(host.gimbal.freshWaypoint)
        var track = HeadTrackNative()
        #expect(track.center(pose: calibration) == .centered)
        let token = try #require(host.gimbal.beginNativeHeadTrack())
        // Implausible live feedback: native 0° while the target sits beside +174.4°.
        host.attitude(nativeTenth: 0, pitchTenth: 56, count: 49)
        let targetLook = track.target(lookRightDeg: 0, lookUpDeg: -2)
        let target = try #require(targetLook)
        #expect(!host.gimbal.updateNativeHeadTrack(target: target, token: token))
        #expect(host.link.nativeTargets.isEmpty)
        #expect(host.link.endedTokens == [token])
    }

    /// OpenPocketCine#638: in FPV every head tracking run jumped the gimbal 73 to 124 degrees on
    /// its first targets, while the Follow run tracked. Head tracking drives Follow and Tilt locked
    /// only, says why, and sends no setup frames in any other mode.
    @Test func headTrackRefusesFPVAndDirectionLockWithoutSendingSetup() throws {
        for (byte, mode) in [(UInt8(0x46), GimbalMode.fpv), (0x06, .directionLock)] {
            let host = Host()
            host.attitude(modeByte: byte)
            #expect(host.gimbalMode == mode)
            let stop = try #require(host.gimbal.headTrackStop)
            #expect(stop.reason == "mode=\(mode.label)")
            #expect(stop.note == "Head tracking is off in \(mode.label). Switch to Follow or Tilt locked, then calibrate")
            #expect(host.gimbal.beginNativeHeadTrack() == nil)
            #expect(host.link.targetTokens.isEmpty && !host.sentHeadTrackPrep)
        }
        for mode in [GimbalMode.follow, .tiltLocked] {
            let host = Host()
            host.gimbalMode = mode
            host.attitude(modeByte: 0x86)
            #expect(host.gimbalMode == mode)
            #expect(host.gimbal.headTrackStop == nil)
            #expect(host.gimbal.beginNativeHeadTrack() != nil)
        }
    }

    @Test func headTrackEndsItsRunWhenTheGimbalSwitchesToFPV() throws {
        let host = Host()
        host.attitude()
        let live = try #require(host.gimbal.freshWaypoint)
        let token = try #require(host.gimbal.beginNativeHeadTrack())
        host.attitude(modeByte: 0x46)
        #expect(!host.gimbal.updateNativeHeadTrack(target: live, token: token))
        #expect(host.link.nativeTargets.isEmpty)
        #expect(host.link.endedTokens == [token])
    }

    /// OpenPocketCine#638: the gimbal sat at 75.1 degrees, past the 70 degree reach. Every target
    /// was refused and head tracking re-armed about 10 times a second, re-sending its setup frames,
    /// with no message. Past the reach it now says so and sends nothing; the stick still works.
    @Test func headTrackPastTheReachSaysSoAndLeavesTheStickWorking() throws {
        let host = Host()
        host.attitude(nativeTenth: 1049, pitchTenth: 751, count: 50)
        let stop = try #require(host.gimbal.headTrackStop)
        #expect(stop.reason == "pastReach")
        #expect(stop.note == "Gimbal past its head tracking range. Recenter, then calibrate")
        #expect(host.gimbal.beginNativeHeadTrack() == nil)
        #expect(host.link.targetTokens.isEmpty && !host.sentHeadTrackPrep)
        host.gimbal.updateStick(x: 0, y: -1)
        #expect(!host.link.sticks.isEmpty)
        host.gimbal.endStick()
        host.attitude(nativeTenth: 1200, pitchTenth: 600, count: 50)
        #expect(host.gimbal.headTrackStop == nil)
    }

    /// Native pitch near level is unverified on hardware (OpenPocketCine#621, #646, #667). Each run
    /// logs its first target, every target on the other side of the 180 degree wrap, and one every
    /// half second, with what went on the wire, the mode and the attitude layout.
    @Test func headTrackLogsTheTargetsItSends() throws {
        let host = Host()
        host.cameraModel = CameraModel(name: "Pocket Test")
        host.attitude(nativeTenth: 1744, pitchTenth: 56, count: 50)
        let calibration = try #require(host.gimbal.freshWaypoint)
        var track = HeadTrackNative()
        #expect(track.center(pose: calibration) == .centered)
        let token = try #require(host.gimbal.beginNativeHeadTrack())
        func send(lookUp: Double) throws {
            let look = track.target(lookRightDeg: 0, lookUpDeg: lookUp)
            let target = try #require(look)
            #expect(host.gimbal.updateNativeHeadTrack(target: target, token: token))
        }
        try send(lookUp: -9)
        try send(lookUp: -8)
        try send(lookUp: 5)
        try send(lookUp: 4)
        host.uptime += 0.5
        host.attitude(nativeTenth: 1744, pitchTenth: 56, count: 50)
        try send(lookUp: 3)
        let lines = host.log.filter { $0.hasPrefix("head-track: target") }
        #expect(
            lines == [
                "head-track: target yaw=0.0 pitch=-3.4 native=183.4 wire=-176.6 live=5.6/174.4 mode=Follow modeFrom=attitude layout=50 model=Pocket Test",
                "head-track: target yaw=0.0 pitch=10.6 native=169.4 wire=169.4 live=5.6/174.4 mode=Follow modeFrom=attitude layout=50 model=Pocket Test",
                "head-track: target yaw=0.0 pitch=8.6 native=171.4 wire=171.4 live=5.6/174.4 mode=Follow modeFrom=attitude layout=50 model=Pocket Test",
            ])
    }

    /// The 49-byte layout carries no known mode field, so the mode is the app's last choice.
    @Test func compactAttitudeLogsTheModeAsTheAppsChoice() throws {
        let host = Host()
        host.attitude(nativeTenth: 1744, pitchTenth: 56, count: 49)
        let live = try #require(host.gimbal.freshWaypoint)
        let token = try #require(host.gimbal.beginNativeHeadTrack())
        #expect(host.gimbal.updateNativeHeadTrack(target: live, token: token))
        let line = try #require(host.log.first { $0.hasPrefix("head-track: target") })
        #expect(line.hasSuffix("mode=Follow modeFrom=app layout=49 model=-"))
    }

    /// Head tracking diagnostics read the newest attitude push as hex and an angle dump; before
    /// any push both are empty.
    @Test func attitudeDiagnosticsDescribeTheNewestPush() {
        let host = Host()
        #expect(host.gimbal.lastAttitudeHex.isEmpty)
        #expect(host.gimbal.lastAttitudeDump.isEmpty)
        host.attitude(modeByte: 0x86)
        host.attitude(modeByte: 0x46)
        #expect(host.gimbal.lastAttitudeHex.hasPrefix("08 07 00 00 00 00 46 00"))
        #expect(host.gimbal.lastAttitudeHex.split(separator: " ").count == 50)
        #expect(host.gimbal.lastAttitudeDump.hasPrefix("n=50 @0=1800 "))
        host.attitude(nativeTenth: 1744, pitchTenth: 56, count: 49)
        #expect(host.gimbal.lastAttitudeDump.hasPrefix("n=49 @0=1744 "))
    }

    @Test func levelWithoutAttitudeSaysSoAndSendsNothing() {
        let host = Host()
        host.gimbalDoubleTap = .level
        host.gimbal.performDoubleTap()
        #expect(host.controlNote == WorldLevelSnap.noLevelData)
        #expect(host.link.sent.isEmpty)
    }
}
