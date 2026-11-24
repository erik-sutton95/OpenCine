package com.opencapture.opencine.insta360.luna

/**
 * Luna live video is TCP: no loss, but the encoder can pause (a format or lens change, a busy
 * body) while the control socket stays up. The ladder asks for keyframes, then restarts live at
 * most [MAXIMUM_RESTARTS] times, one at a time and [RESTART_SPACING] seconds apart, then gives the
 * stall to bounded session recovery. A 1 Hz restart loop with no end kept a reconfiguring body
 * from settling and left the operator on Reconnecting for good (owner, 2026-10-19).
 *
 * While the camera records, the ladder only asks for keyframes until video has been gone
 * [RECORDING_RESTART_AFTER]. With Color Recovery on (I-Log graded into the preview) starting a
 * recording can pause the preview encoder for seconds, and a live restart (stop live, the
 * shooting-view file state, start live) or session recovery during the take ended it: the picture
 * froze and the camera dropped back to monitoring (OPENINSTACINE-IOS-S). A frozen monitor costs the
 * operator a few seconds of picture; a stopped take costs the shot. So the take is left alone until
 * the silence outlasts [ESCALATE_AFTER], the longest the normal ladder ever waits before it declares
 * the link lost: no encoder pause seen on a Luna lasts that long, so by then video has truly gone and
 * the ordinary repair runs, shifted by that bound (restarts, then session recovery at
 * [RECORDING_ESCALATE_AFTER] at the latest). Once the recording stops the normal ladder resumes.
 * The Swift twin is `LunaFeedStall` in Insta360Apple.
 */
class LunaFeedStall {
    enum class Action { NONE, REQUEST_KEYFRAME, RESTART_LIVE, ESCALATE }

    var restarts = 0
        private set
    var restartInFlight = false
        private set
    private var lastRestartAt: Double? = null
    private var escalated = false

    /**
     * One watchdog tick. [silence] is seconds since the last video unit; [now] is monotonic seconds;
     * [recording] is whether the camera is recording (or a record start or stop is in flight).
     */
    @Synchronized
    fun tick(silence: Double, now: Double, recording: Boolean = false): Action {
        if (silence <= KEYFRAME_AFTER) {
            reset()
            return Action.NONE
        }
        if (escalated) return Action.NONE
        if (recording && silence <= RECORDING_RESTART_AFTER) return Action.REQUEST_KEYFRAME
        val ceiling = if (recording) RECORDING_ESCALATE_AFTER else ESCALATE_AFTER
        val restartAt = if (recording) RECORDING_RESTART_AFTER else RESTART_AFTER
        val spaced = lastRestartAt?.let { now - it >= RESTART_SPACING } ?: true
        if (silence > ceiling || (restarts >= MAXIMUM_RESTARTS && spaced && !restartInFlight)) {
            escalated = true
            return Action.ESCALATE
        }
        if (silence <= restartAt) return Action.REQUEST_KEYFRAME
        if (restartInFlight || restarts >= MAXIMUM_RESTARTS || !spaced) return Action.NONE
        restarts += 1
        restartInFlight = true
        lastRestartAt = now
        return Action.RESTART_LIVE
    }

    /** The restart's commands returned (answered or failed); the next one may follow when spaced. */
    @Synchronized
    fun restartFinished() {
        restartInFlight = false
    }

    private fun reset() {
        restarts = 0
        restartInFlight = false
        lastRestartAt = null
        escalated = false
    }

    companion object {
        const val KEYFRAME_AFTER = 2.0
        const val RESTART_AFTER = 6.0
        const val RESTART_SPACING = 8.0
        const val MAXIMUM_RESTARTS = 2
        /** The hard ceiling, also when a restart is still waiting on the camera. */
        const val ESCALATE_AFTER = 30.0
        /** While recording: no live restart and no session recovery before video has been gone this long. */
        const val RECORDING_RESTART_AFTER = ESCALATE_AFTER
        /** While recording: the hard ceiling, the normal one shifted by [RECORDING_RESTART_AFTER]. */
        const val RECORDING_ESCALATE_AFTER = RECORDING_RESTART_AFTER + ESCALATE_AFTER
    }
}
