import OpenCineCameraVocabulary

/// Nikon's bound on one session-recovery attempt: the PTP connect, the property bootstrap and
/// the first live-view picture. Recovery connects run without the phase watchdog, and a dial
/// into a vanished network can block a socket past every cancellation, so every attempt needs a
/// ceiling of its own inside the shared 180 s budget. The Kotlin twin is
/// `NIKON_RECOVERY_ATTEMPT_DEADLINE` in `:nikon`.
public enum NikonSessionRecovery {
    public static let attemptDeadline = SessionRecoveryEpisode.AttemptDeadline(
        attempt: .seconds(30))
}
