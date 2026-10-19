package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.insta360.luna.LunaFeedStall.Action
import kotlin.test.*
import org.junit.Test

/** Swift `LunaFeedStallTests`: keyframes, then bounded single-flight restarts, then session recovery. */
class LunaFeedStallTest {
    /** Ticks once a second while video stays silent, finishing each restart at once. */
    private fun run(stall: LunaFeedStall, seconds: IntRange): Map<Int, Action> {
        val actions = mutableMapOf<Int, Action>()
        for (second in seconds) {
            val action = stall.tick(second.toDouble(), second.toDouble())
            if (action != Action.NONE) actions[second] = action
            if (action == Action.RESTART_LIVE) stall.restartFinished()
        }
        return actions
    }

    @Test fun aStallAsksForKeyframesThenRestartsTwiceThenEscalatesOnce() {
        val actions = run(LunaFeedStall(), 1..60)
        assertEquals(listOf(3, 4, 5, 6), actions.filterValues { it == Action.REQUEST_KEYFRAME }.keys.sorted())
        assertEquals(listOf(7, 15), actions.filterValues { it == Action.RESTART_LIVE }.keys.sorted())
        assertEquals(listOf(23), actions.filterValues { it == Action.ESCALATE }.keys.sorted(),
            "the stall ends in session recovery instead of restarting live forever")
    }

    @Test fun aRestartStillWaitingOnTheCameraIsNeverStackedAndTheCeilingStillEscalates() {
        val stall = LunaFeedStall()
        var restarts = 0
        var escalatedAt: Int? = null
        for (second in 1..60) {
            when (stall.tick(second.toDouble(), second.toDouble())) {
                Action.RESTART_LIVE -> restarts += 1 // never finished: the camera does not answer
                Action.ESCALATE -> if (escalatedAt == null) escalatedAt = second
                else -> {}
            }
        }
        assertEquals(1, restarts)
        assertEquals(31, escalatedAt)
    }

    @Test fun videoReturningResetsTheLadder() {
        val stall = LunaFeedStall()
        run(stall, 1..16)
        assertEquals(2, stall.restarts)
        assertEquals(Action.NONE, stall.tick(0.1, 17.0))
        assertEquals(0, stall.restarts)
        assertEquals(Action.RESTART_LIVE, stall.tick(7.0, 24.0), "a later stall gets its own bounded restarts")
    }

    @Test fun aShortFormatChangeGapOnlyAsksForKeyframes() {
        val stall = LunaFeedStall()
        assertEquals(setOf(Action.REQUEST_KEYFRAME), run(stall, 1..5).values.toSet())
        assertEquals(Action.NONE, stall.tick(0.2, 6.0))
    }
}
