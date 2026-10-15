package com.opencapture.opencine.multicam

import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.djiLike
import com.opencapture.opencine.core.testing.nikonLike
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.async
import kotlinx.coroutines.yield

/** A4-19: one record-all policy, plan rule and copy for every app. */
class RecordAllTests {
    @Test
    fun oneCameraThatCannotRecordCommandsNone() = scenario {
        val ready = reported(FakeCameraSession.djiLike())
        val waiting = FakeCameraSession.nikonLike().apply { cameraReportsStatus() } // no live view yet
        val cameras = listOf(ready, waiting)
        val a = entry("A", ready)
        val b = entry("B", waiting)
        val g = group(listOf(a, b))
        val live = state(cameras)

        val plan = RecordAll.plan(listOf(a.id, b.id), { false }, g, live)
        assertEquals(TargetPolicy.STRICT, plan.policy)
        assertEquals(RecordDirection.START, plan.direction)
        assertTrue(plan.isRefused)
        assertNull(RecordAll.run(plan, g, live, sessions(cameras)))
        assertTrue(ready.wire.isEmpty())
        assertTrue(waiting.wire.isEmpty())
    }

    @Test
    fun anyCameraRecordingMakesThePressAStop() = scenario {
        val a = reported(FakeCameraSession.djiLike())
        val entryA = entry("A", a)
        val g = group(listOf(entryA))
        assertEquals(RecordDirection.STOP, RecordAll.plan(listOf(entryA.id), { true }, g, state(listOf(a))).direction)
    }

    @Test
    fun everyCameraConfirmsAndTheSummarySaysSo() = scenario {
        val cameras = listOf(reported(FakeCameraSession.djiLike()), reported(FakeCameraSession.djiLike()))
        val entries = cameras.mapIndexed { index, camera -> entry("$index", camera) }
        val g = group(entries)
        val live = state(cameras)
        val plan = RecordAll.plan(entries.map { it.id }, { false }, g, live)
        val running = async { RecordAll.run(plan, g, live, sessions(cameras)) }
        while (cameras.any { it.wire.isEmpty() }) yield()
        advance(cameras, 1.seconds)
        val result = running.await()!!
        assertEquals("Recording on 2 cameras", RecordAll.summary(result, allMatch = true))
        assertEquals("1 of 2 confirmed · check camera tiles",
            RecordAll.summary(result.copy(outcomes = result.outcomes.toMutableMap().apply {
                put(cameras[1].id, TargetOutcome.TimedOut)
            }), allMatch = false))
    }

    @Test
    fun theOperatorsWordsForEachOutcome() {
        val start = RecordDirection.START
        assertEquals("Recording", RecordAll.note(TargetOutcome.Confirmed, start))
        assertEquals("Recording stopped", RecordAll.note(TargetOutcome.Confirmed, RecordDirection.STOP))
        assertEquals("Recording command rejected · check camera",
            RecordAll.note(TargetOutcome.Rejected(CommandRejection.CameraRefused), start))
        assertEquals("Not sent · check camera", RecordAll.note(TargetOutcome.Failed(CommandFailure.NOT_SENT), start))
        assertEquals("No confirmation · check camera", RecordAll.note(TargetOutcome.TimedOut, start))
        assertNull(RecordAll.note(TargetOutcome.Superseded, start))
        assertEquals("Starting cameras…", RecordAll.progress(start))
    }
}
