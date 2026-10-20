package com.opencapture.opencine.nikon

/**
 * One press of the app's shutter control, from finger-down until its run ends. Kotlin twin of
 * the Swift core `StillShutterHold` (`StillCapture.swift`); the rules are the same.
 *
 * A tap takes exactly one frame in every drive mode, as the body's own shutter does. So the first
 * release of a press is always a plain single-frame release: it never opens the burst bracket,
 * and a finger-up never cancels or terminates it. Only while the finger stays down in a
 * continuous drive does the press chain burst runs; those open the remote-mode bracket and a
 * finger-up terminates the one in flight. Thread-safe: the press and finger-up arrive on the UI
 * thread while the release run reads it. [verify-on-HW: one frame per tap in CL, CH and CH+]
 */
public class StillShutterHold(public val continuousDrive: Boolean) {
    /** What the next release of this press is. */
    public enum class Release {
        /** The press's first release: one frame, outside the burst bracket. */
        SINGLE_FRAME,

        /** A chained release while the finger stays down, inside the burst bracket. */
        BURST_RUN,
    }

    /** What a finger-up asks the shell to do. */
    public enum class FingerUp {
        /** Let the release in flight finish on its own. */
        LET_RELEASE_FINISH,

        /** Stop the burst: terminate the chained run in flight. */
        END_BURST,
    }

    /** Whether the finger is still on the control. */
    @get:Synchronized
    public var isHeld: Boolean = true
        private set

    /** Burst runs chained after the first release. */
    @get:Synchronized
    public var burstRuns: Int = 0
        private set

    /** The kind of the release the shell sends next. */
    public val nextRelease: Release
        @Synchronized get() = if (burstRuns == 0) Release.SINGLE_FRAME else Release.BURST_RUN

    /** Finger-up. Only a press that already chained a burst run has anything to end. */
    @Synchronized
    public fun fingerUp(): FingerUp {
        if (!isHeld) return FingerUp.LET_RELEASE_FINISH
        isHeld = false
        return if (burstRuns > 0) FingerUp.END_BURST else FingerUp.LET_RELEASE_FINISH
    }

    /** A release completed. True when the press chains a burst run next. */
    @Synchronized
    public fun releaseCompleted(): Boolean {
        if (!continuousDrive || !isHeld || burstRuns >= MAXIMUM_BURST_RUNS) return false
        burstRuns += 1
        return true
    }

    public companion object {
        /** Chained burst runs one press may add; backstops a finger-up the system swallowed. */
        public const val MAXIMUM_BURST_RUNS: Int = 30
    }
}
