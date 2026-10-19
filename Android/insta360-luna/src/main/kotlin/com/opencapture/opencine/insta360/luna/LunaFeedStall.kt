package com.opencapture.opencine.insta360.luna

/**
 * Luna live video is TCP: no loss, but the encoder can pause (a format or lens change, a busy
 * body) while the control socket stays up. The ladder asks for keyframes, then restarts live at
 * most [MAXIMUM_RESTARTS] times, one at a time and [RESTART_SPACING] seconds apart, then gives the
 * stall to bounded session recovery. A 1 Hz restart loop with no end kept a reconfiguring body
 * from settling and left the operator on Reconnecting for good (owner, 2026-10-19). The Swift twin
 * is `LunaFeedStall` in Insta360Apple.
 */
class LunaFeedStall {
    enum class Action { NONE, REQUEST_KEYFRAME, RESTART_LIVE, ESCALATE }

    var restarts = 0
        private set
    var restartInFlight = false
        private set
    private var lastRestartAt: Double? = null
    private var escalated = false

    /** One watchdog tick. [silence] is seconds since the last video unit; [now] is monotonic seconds. */
    @Synchronized
    fun tick(silence: Double, now: Double): Action {
        if (silence <= KEYFRAME_AFTER) {
            reset()
            return Action.NONE
        }
        if (escalated) return Action.NONE
        val spaced = lastRestartAt?.let { now - it >= RESTART_SPACING } ?: true
        if (silence > ESCALATE_AFTER || (restarts >= MAXIMUM_RESTARTS && spaced && !restartInFlight)) {
            escalated = true
            return Action.ESCALATE
        }
        if (silence <= RESTART_AFTER) return Action.REQUEST_KEYFRAME
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
    }
}
