import Testing

@testable import OpenCineDJI

/// The DJI member link's own recovery ladder (moved from OpenPocketCine's `MultiviewStageTests`
/// with Shared Multiview Plan 3: the ladder is DJI's, the budget around it the coordinator's).
@Suite struct MultiviewRecoveryTests {
    @Test func recoveryDoesNotResetHealthyVideoForStalePresentation() {
        var recovery = MultiviewRecovery()
        let snapshot = FeedWatchdog.Snapshot(
            now: 100, lastDecodedFrameAge: 20, lastVideoPacketAge: 0.01,
            lastStatusAge: 0.1, flowHealthy: true, pathReady: true, hasFormat: true,
            decoderFailed: false, live: true, sawPicture: true,
            secondsSinceLastEnable: 50)
        let action = recovery.action(snapshot)
        #expect(action == .none)
    }

    @Test func firstPictureFailureEscalatesBeyondBaseCooldown() {
        var recovery = MultiviewRecovery()
        func snapshot(_ time: Double) -> FeedWatchdog.Snapshot {
            FeedWatchdog.Snapshot(
                now: time, lastDecodedFrameAge: nil, lastVideoPacketAge: nil,
                lastStatusAge: nil, flowHealthy: true, pathReady: true, hasFormat: false,
                decoderFailed: false, live: true, sawPicture: false, hadVideo: false,
                secondsSinceLastEnable: 50)
        }
        var noNetwork = snapshot(130)
        noNetwork.pathReady = false
        var recentEnable = snapshot(130)
        recentEnable.secondsSinceLastEnable = 1
        let actions = [snapshot(100), snapshot(110), snapshot(120), noNetwork, recentEnable, snapshot(130)]
            .map { recovery.action($0) }
        #expect(
            actions == [
                .resendLiveViewEnable, .reopenDatalink, .none, .none, .none, .fullSessionRejoin,
            ])
    }
}
