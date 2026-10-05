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
        func noteNativeTarget(_ frame: Duml.Frame, token: UInt64) -> Bool { true }
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

    @Test func levelWithoutAttitudeSaysSoAndSendsNothing() {
        let host = Host()
        host.gimbalDoubleTap = .level
        host.gimbal.performDoubleTap()
        #expect(host.controlNote == WorldLevelSnap.noLevelData)
        #expect(host.link.sent.isEmpty)
    }
}
