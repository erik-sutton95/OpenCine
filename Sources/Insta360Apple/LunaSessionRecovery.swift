import OpenCineCameraVocabulary

/// Luna's bound on one session-recovery attempt: the Bluetooth bootstrap or saved Wi-Fi, the
/// network join, the video link and the first picture inside the shared 180 s budget. Once the
/// link reports live, a fresh picture must follow within one stage ceiling (the body sends a GOP
/// about every 2 s). The Kotlin twin is `LUNA_RECOVERY_ATTEMPT_DEADLINE` in `:insta360-luna`.
public enum LunaSessionRecovery {
    public static let attemptDeadline = SessionRecoveryEpisode.AttemptDeadline(
        attempt: .seconds(90), stages: [.live: .seconds(10)])
}
