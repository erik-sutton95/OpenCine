import OpenCineCameraVocabulary
import Testing

/// Hardware pass 4.1: a phone that stopped reconnecting kept saying it held the camera, so the
/// phone that took it read its own later drop as a take-over, and both phones ended on "Camera
/// taken over" with a "Reconnecting" pill (Kotlin `SessionRecoveryClaimTest`).
@Suite("Session recovery camera claim")
struct SessionRecoveryClaimTests {
    private let states: [SessionRecoveryState] = [
        .idle, .retrying(attempt: 1, maxAttempts: 8), .waitingForOperator(attemptsMade: 8),
        .pausedAfterRepeatedDrops(drops: 3), .takenOver(holder: "iPhone"),
    ]

    @Test func onlyALiveSessionOrARunningReconnectClaimsTheCamera() {
        #expect(states.map(\.claimsCamera) == [true, true, false, false, false])
    }

    @Test func onlyARunningReconnectSaysReconnecting() {
        #expect(states.map(\.isReconnecting) == [false, true, false, false, false])
    }
}
