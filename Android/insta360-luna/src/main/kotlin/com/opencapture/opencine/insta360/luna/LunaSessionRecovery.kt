package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.vocabulary.SessionRecoveryEpisode

/**
 * Luna's bound on one session-recovery attempt: the Bluetooth bootstrap or saved Wi-Fi, the
 * network join, the video link and the first picture inside the shared 180 s budget. Once the
 * link reports live, a fresh picture must follow within one stage ceiling (the body sends a GOP
 * about every 2 s). The Swift twin is `LunaSessionRecovery.attemptDeadline` in Insta360Apple.
 */
val LUNA_RECOVERY_ATTEMPT_DEADLINE =
    SessionRecoveryEpisode.AttemptDeadline(
        attemptMs = 90_000,
        stagesMs = mapOf(SessionRecoveryEpisode.Stage.LIVE to 10_000L),
    )
