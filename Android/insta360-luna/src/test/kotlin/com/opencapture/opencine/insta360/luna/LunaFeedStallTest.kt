package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.insta360.luna.LunaFeedStall.Action
import kotlin.test.*
import org.junit.Test

/** Swift `LunaFeedStallTests`: keyframes, then bounded single-flight restarts, then session recovery. */
class LunaFeedStallTest {
    /** Ticks once a second while video stays silent, finishing each restart at once. */
    private fun run(stall: LunaFeedStall, seconds: IntRange, recording: Boolean = false): Map<Int, Action> {
        val actions = mutableMapOf<Int, Action>()
        for (second in seconds) {
            val action = stall.tick(second.toDouble(), second.toDouble(), recording)
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

    // Recording (OPENINSTACINE-IOS-S)

    @Test fun notRecordingKeepsTheNormalLadder() {
        val actions = run(LunaFeedStall(), 1..60, recording = false)
        assertEquals(listOf(7, 15), actions.filterValues { it == Action.RESTART_LIVE }.keys.sorted())
        assertEquals(listOf(23), actions.filterValues { it == Action.ESCALATE }.keys.sorted())
    }

    @Test fun aRecordStartPauseOnlyAsksForKeyframesAndNeverTouchesTheTake() {
        val stall = LunaFeedStall()
        val actions = run(stall, 1..30, recording = true)
        assertEquals(setOf(Action.REQUEST_KEYFRAME), actions.values.toSet(),
            "a restart (stop live, file state, start live) or session recovery can end the take")
        assertEquals((3..30).toList(), actions.keys.sorted())
        assertEquals(Action.NONE, stall.tick(0.2, 31.0, recording = true))
    }

    @Test fun videoGoneLongerThanTheRecordingBoundRestartsThenEscalates() {
        val actions = run(LunaFeedStall(), 1..90, recording = true)
        assertEquals(listOf(31, 39), actions.filterValues { it == Action.RESTART_LIVE }.keys.sorted())
        assertEquals(listOf(47), actions.filterValues { it == Action.ESCALATE }.keys.sorted())
    }

    @Test fun whileRecordingAnUnansweredRestartEscalatesAtTheRecordingCeiling() {
        val stall = LunaFeedStall()
        val restarts = mutableListOf<Int>()
        var escalatedAt: Int? = null
        for (second in 1..90) {
            when (stall.tick(second.toDouble(), second.toDouble(), recording = true)) {
                Action.RESTART_LIVE -> restarts += second // never finished
                Action.ESCALATE -> if (escalatedAt == null) escalatedAt = second
                else -> {}
            }
        }
        assertEquals(listOf(31), restarts)
        assertEquals(61, escalatedAt)
    }

    @Test fun stoppingTheRecordingResumesTheNormalLadder() {
        val stall = LunaFeedStall()
        assertEquals(setOf(Action.REQUEST_KEYFRAME), run(stall, 1..10, recording = true).values.toSet())
        assertEquals(Action.RESTART_LIVE, stall.tick(11.0, 11.0, recording = false),
            "once the take ends the stall is repaired as before")
    }
}
