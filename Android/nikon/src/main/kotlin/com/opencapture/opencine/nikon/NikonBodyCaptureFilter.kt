package com.opencapture.opencine.nikon

/** How a shell reacts to a capture event it did not ask for. Twin of Swift `NikonBodyCaptureSync`. */
public enum class NikonBodyCaptureSync {
    /** Movie mode, the app's own release, or one more event of a run already synced. */
    IGNORE,

    /** Photo mode without instant review: refresh the remaining-shots readout only. */
    SHOTS_ONLY,

    /** Photo mode with instant review: review the shot and refresh the remaining shots. */
    REVIEW_AND_SHOTS,
}

/**
 * Tells a shot fired on the body apart from the late card objects of the app's own release.
 * Kotlin twin of the Swift core `NikonBodyCaptureFilter` (`NikonStillReview.swift`).
 *
 * The app's release completes before all of its objects reach the card (the second half of a
 * RAW+JPEG pair, a burst's later frames). Every event within [APP_RELEASE_TAIL_MILLIS] of the
 * app's release, or of the previous late object, belongs to that release, so it never restarts
 * the app's own review. A real body run is synced once, then quiet for
 * [BODY_RUN_DEBOUNCE_MILLIS] after each of its events. Times are any monotonic clock in
 * milliseconds. [verify-on-HW: object arrival after a RAW+JPEG release per body]
 */
public class NikonBodyCaptureFilter {
    private var appReleaseTailUntil: Long? = null
    private var bodyRunQuietUntil: Long? = null

    /** The app's own release run completed at [now]. */
    @Synchronized
    public fun appReleaseCompleted(now: Long) {
        appReleaseTailUntil = now + APP_RELEASE_TAIL_MILLIS
    }

    /** Classifies one capture event at [now]. */
    @Synchronized
    public fun action(
        now: Long,
        isPhotography: Boolean,
        instantReviewEnabled: Boolean,
        appReleaseInFlight: Boolean,
    ): NikonBodyCaptureSync {
        if (!isPhotography || appReleaseInFlight) return NikonBodyCaptureSync.IGNORE
        val tail = appReleaseTailUntil
        if (tail != null && now < tail) {
            appReleaseTailUntil = now + APP_RELEASE_TAIL_MILLIS
            return NikonBodyCaptureSync.IGNORE
        }
        appReleaseTailUntil = null
        val quiet = bodyRunQuietUntil
        bodyRunQuietUntil = now + BODY_RUN_DEBOUNCE_MILLIS
        if (quiet != null && now < quiet) return NikonBodyCaptureSync.IGNORE
        return if (instantReviewEnabled) {
            NikonBodyCaptureSync.REVIEW_AND_SHOTS
        } else {
            NikonBodyCaptureSync.SHOTS_ONLY
        }
    }

    public companion object {
        /** Swift `NikonStillReviewPolicy.objectWindowMilliseconds`. */
        public const val APP_RELEASE_TAIL_MILLIS: Long = 4_000L

        /** Quiet period after a synced body capture, so one body burst syncs once. */
        public const val BODY_RUN_DEBOUNCE_MILLIS: Long = 800L
    }
}
