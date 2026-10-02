package com.opencapture.opencine.multicam

import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.Freshness
import com.opencapture.opencine.core.PictureHealth
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.UnavailableReason
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.FakeDevice
import com.opencapture.opencine.core.testing.FakeEntries
import com.opencapture.opencine.core.testing.FakePictureSource
import com.opencapture.opencine.core.testing.djiLike
import com.opencapture.opencine.core.testing.lunaLike
import com.opencapture.opencine.core.testing.nikonLike
import com.opencapture.opencine.multicam.RecordDirection.START
import com.opencapture.opencine.multicam.RecordDirection.STOP
import com.opencapture.opencine.multicam.TargetPolicy.ELIGIBLE_SUBSET
import com.opencapture.opencine.multicam.TargetPolicy.STRICT
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/** Swift suite `GroupRecordTests`: plan 8.2 and the Multi View rows of the 11.3 regression matrix, on Core fakes. */
class GroupRecordTests {
    @Test
    fun mixedSupportAndMissingPictureOrControl() = scenario {
        val dji = reported(FakeCameraSession.djiLike())
        val noLiveView = FakeCameraSession.nikonLike().apply { cameraReportsStatus() }
        val photo = reported(FakeCameraSession.djiLike()).apply { cameraSwitchesMode(0x05) }
        val silent = FakeCameraSession.lunaLike()
        val hdmi = FakePictureSource("HDMI").descriptor
        val a = entry("A", dji)
        val b = FakeEntries.controlOnly(noLiveView.id, "B")
        val c = entry("C", photo)
        val d = FakeEntries.captureOnly(hdmi)
        val e = entry("E", silent)
        val g = group(listOf(a, b, c, d, e))
        val live = state(
            listOf(dji, noLiveView, photo, silent),
            pictures = mapOf(hdmi.stream to PictureHealth.LIVE, a.picture!!.stream to PictureHealth.LIVE),
        )

        val plan = RecordPlan.make(START, ELIGIBLE_SUBSET, g.entries.map { it.id }, g, live)
        assertEquals(listOf(listOf(a.id)), plan.targets.map { it.entries })
        assertEquals(
            listOf(
                Exclusion(b.id, ExclusionReason.Rejected(CommandRejection.Unavailable(UnavailableReason.NotReady))),
                Exclusion(c.id, ExclusionReason.Rejected(CommandRejection.Unavailable(UnavailableReason.Mode))),
                Exclusion(d.id, ExclusionReason.NoCameraSession),
                Exclusion(e.id, ExclusionReason.Rejected(CommandRejection.SupportUnknown)),
            ),
            plan.exclusions,
        )

        val summary = g.summary(live, 3.seconds)
        val by = summary.entries.associateBy { it.entry }
        assertEquals(RoleStatus.Reported(PictureHealth.LIVE), by[d.id]?.picture)
        assertEquals(RoleStatus.Absent, by[d.id]?.control)
        assertEquals(RoleStatus.Absent, by[b.id]?.picture)
        assertEquals(RoleStatus.Reported(ConnectionState.Ready), by[b.id]?.control)
        assertEquals(RoleStatus.Unreported, by[c.id]?.picture)
        assertEquals(false, by[e.id]?.recording?.isKnown)
        assertEquals(Freshness.UNKNOWN, by[e.id]?.telemetry)
        assertEquals(1, summary.camerasRecordingUnknown)
        assertEquals(4, summary.camerasReady)
        assertEquals(2, summary.livePictures)
    }

    @Test
    fun strictRefusesWhileEligibleSubsetStatesExclusions() = scenario {
        val dji = reported(FakeCameraSession.djiLike())
        val nikon = FakeCameraSession.nikonLike().apply { cameraReportsStatus() } // its record control waits for live view
        val cameras = listOf(dji, nikon)
        val a = entry("A", dji)
        val b = entry("B", nikon)
        val g = group(listOf(a, b))
        val live = state(cameras)

        val strict = RecordPlan.make(START, STRICT, listOf(a.id, b.id), g, live)
        assertTrue(strict.isRefused)
        assertEquals(
            listOf(Exclusion(b.id, ExclusionReason.Rejected(CommandRejection.Unavailable(UnavailableReason.NotReady)))),
            strict.exclusions,
        )
        val refused = assertFailsWith<RecordSubmissionException> { strict.submit(g, live, sessions(cameras)) }
        assertEquals(RecordSubmissionError.NOT_EXECUTABLE, refused.error)
        assertTrue(dji.wire.isEmpty())

        val busy = state(cameras, busy = setOf(a.id))
        assertEquals(
            listOf(Exclusion(a.id, ExclusionReason.Busy)),
            RecordPlan.make(START, ELIGIBLE_SUBSET, listOf(a.id), g, busy).exclusions,
        )

        val subset = RecordPlan.make(START, ELIGIBLE_SUBSET, listOf(a.id, b.id), g, live)
        assertFalse(subset.isRefused)
        val submission = subset.submit(g, live, sessions(cameras), maxConcurrent = 1)
        advance(cameras, 1.seconds)
        val result = submission.finished(sessions(cameras))
        assertEquals(mapOf(dji.id to TargetOutcome.Confirmed), result.outcomes)
        assertEquals(TargetOutcome.Confirmed, result.outcome(a.id, g))
        assertNull(result.outcome(b.id, g))
        assertEquals(listOf("record-toggle"), dji.wire)
        assertTrue(nikon.wire.isEmpty())

        // Already rolling: counted as satisfied, never commanded again.
        val again = RecordPlan.make(START, STRICT, listOf(a.id), g, state(listOf(dji)))
        assertTrue(again.targets.isEmpty())
        assertEquals(listOf(dji.id), again.satisfied.map { it.session })
        assertFalse(again.isExecutable)
    }

    @Test
    fun entriesSharingOneSessionGetOneCommandAndShareItsResult() = scenario {
        val dji = reported(FakeCameraSession.djiLike())
        val picture = entry("A", dji)
        val controls = FakeEntries.controlOnly(dji.id, "A controls")
        val relay = entry("A relay", dji, authority = ControlAuthority.ReadOnly)
        val g = group(listOf(picture, controls, relay))
        val live = state(listOf(dji))

        val plan = RecordPlan.make(START, STRICT, g.entries.map { it.id }, g, live)
        assertEquals(1, plan.targets.size)
        assertEquals(listOf(picture.id, controls.id, relay.id), plan.targets.first().entries)
        assertTrue(plan.exclusions.isEmpty())
        val submission = plan.submit(g, live, sessions(listOf(dji)))
        dji.advance(1.seconds)
        val result = submission.finished(sessions(listOf(dji)))
        for (id in listOf(picture.id, controls.id, relay.id)) {
            assertEquals(TargetOutcome.Confirmed, result.outcome(id, g))
        }
        assertEquals(listOf("record-toggle"), dji.wire)
        val after = state(listOf(dji))
        assertEquals(1, g.summary(after, 3.seconds).camerasRecording)

        // The read-only view alone cannot command its camera.
        val readOnly = RecordPlan.make(STOP, ELIGIBLE_SUBSET, listOf(relay.id), g, after)
        assertEquals(listOf(Exclusion(relay.id, ExclusionReason.NoCommandAuthority)), readOnly.exclusions)
    }

    @Test
    fun partialFailureKeepsIndividualResultsAndNeverCompensates() = scenario {
        val dji = reported(FakeCameraSession.djiLike())
        val nikon = reported(FakeCameraSession.nikonLike())
        val luna = reported(FakeCameraSession.lunaLike())
        val cameras = listOf(dji, nikon, luna)
        val entries = listOf(entry("A", dji), entry("B", nikon), entry("C", luna))
        val g = group(entries)
        nikon.refuseNextCommand()
        luna.silenceReports(true)
        val live = state(cameras)

        val plan = RecordPlan.make(START, STRICT, entries.map { it.id }, g, live)
        val submission = plan.submit(g, live, sessions(cameras), deadline = 4.seconds)
        assertEquals(CommandStage.Rejected(CommandRejection.CameraRefused), submission.receipts[nikon.id]?.stage)
        assertEquals(TargetOutcome.Accepted, submission.current(sessions(cameras)).outcomes[dji.id])
        advance(cameras, 10.seconds)
        val result = submission.finished(sessions(cameras))
        assertEquals(
            mapOf(
                dji.id to TargetOutcome.Confirmed,
                nikon.id to TargetOutcome.Rejected(CommandRejection.CameraRefused),
                luna.id to TargetOutcome.TimedOut,
            ),
            result.outcomes,
        )
        assertEquals(1, result.confirmed)

        // No compensation: the camera that started is never stopped because others failed.
        assertEquals(listOf("record-toggle"), dji.wire)
        assertEquals(true, dji.device.recording)
        // A timeout never fabricates a reported state.
        val after = g.summary(state(cameras), 30.seconds)
        assertEquals(RecordingState.IDLE, after.entries[2].recording.value)
        assertEquals(1, after.camerasRecording)

        // Removing the failed entry and closing sessions never stop a recording.
        g.remove(entries[1].id)
        nikon.close(SessionCloseReason.REQUESTED)
        dji.close(SessionCloseReason.REQUESTED)
        assertEquals(listOf("record-toggle"), dji.wire)
        assertEquals(true, dji.device.recording)
    }

    @Test
    fun routineTelemetryDoesNotInvalidateAPlan() = scenario {
        val dji = reported(FakeCameraSession.djiLike())
        val nikon = reported(FakeCameraSession.nikonLike())
        val cameras = listOf(dji, nikon)
        val entries = listOf(entry("A", dji), entry("B", nikon))
        val g = group(entries)
        val before = state(cameras)
        val plan = RecordPlan.make(START, STRICT, entries.map { it.id }, g, before)

        advance(cameras, 1.seconds)
        for (camera in cameras) camera.cameraReportsStatus()
        val later = state(cameras, pictures = mapOf(entries[0].picture!!.stream to PictureHealth.STALLED))
        assertNotEquals(before.cameras[dji.id]?.revision, later.cameras[dji.id]?.revision)
        assertTrue(plan.isCurrent(g, later))
        plan.submit(g, later, sessions(cameras))
        assertEquals(listOf("record-toggle"), dji.wire)
        assertEquals(listOf("record-start"), nikon.wire)
    }

    @Test
    fun replacementSessionEpochOrModeChangeInvalidatesAPlan() = scenario {
        val dji = reported(FakeCameraSession.djiLike())
        val a = entry("A", dji)
        val g = group(listOf(a))
        fun plan() = RecordPlan.make(START, STRICT, listOf(a.id), g, state(listOf(dji)))

        val beforeRecovery = plan()
        dji.completeAttempt(dji.loseLink())
        assertFalse(beforeRecovery.isCurrent(g, state(listOf(dji))))

        val beforeModeChange = plan()
        dji.cameraSwitchesMode(0x02)
        assertFalse(beforeModeChange.isCurrent(g, state(listOf(dji))))

        val beforeReplacement = plan()
        val replacement = reported(FakeCameraSession.djiLike())
        g.replaceSession(a.id, replacement)
        val now = state(listOf(dji, replacement))
        assertFalse(beforeReplacement.isCurrent(g, now))
        val stale = assertFailsWith<RecordSubmissionException> {
            beforeReplacement.submit(g, now, sessions(listOf(dji, replacement)))
        }
        assertEquals(RecordSubmissionError.STALE, stale.error)
        assertTrue(dji.wire.isEmpty())
        assertTrue(replacement.wire.isEmpty())
    }

    @Test
    fun lateResultFromAReplacedSessionNeverLandsOnTheReplacement() = scenario {
        val old = reported(FakeCameraSession.nikonLike())
        val a = entry("A", old)
        val g = group(listOf(a))
        val live = state(listOf(old))
        val plan = RecordPlan.make(START, STRICT, listOf(a.id), g, live)
        val submission = plan.submit(g, live, sessions(listOf(old)))

        // The app replaces the session before the old camera confirms.
        val replacement = reported(FakeCameraSession.nikonLike())
        g.replaceSession(a.id, replacement)
        old.advance(1.seconds)
        val result = submission.finished(sessions(listOf(old, replacement)))
        assertEquals(TargetOutcome.Confirmed, result.outcomes[old.id])
        assertEquals(TargetOutcome.Superseded, result.outcome(a.id, g))
        assertTrue(replacement.wire.isEmpty())
        val summary = g.summary(state(listOf(old, replacement)), 5.seconds)
        assertEquals(RecordingState.IDLE, summary.entries[0].recording.value)
    }

    @Test
    fun targetWithoutARuntimeSessionFailsAsNotSent() = scenario {
        val dji = reported(FakeCameraSession.djiLike())
        val a = entry("A", dji)
        val g = group(listOf(a))
        val live = state(listOf(dji))
        val plan = RecordPlan.make(START, STRICT, listOf(a.id), g, live)
        val submission = plan.submit(g, live, emptyMap())
        assertEquals(CommandStage.Failed(CommandFailure.NOT_SENT), submission.receipts[dji.id]?.stage)
        assertEquals(
            mapOf(dji.id to TargetOutcome.Failed(CommandFailure.NOT_SENT)),
            submission.finished(emptyMap()).outcomes,
        )
        assertTrue(dji.wire.isEmpty())
    }

    @Test
    fun unreportedRecordingStateIsExcludedNeverCommanded() = scenario {
        val dji = reported(FakeCameraSession.djiLike())
        val silent = reported(
            FakeCameraSession(
                FakeCameraSession.djiLike().behavior,
                FakeDevice(rawMode = 0x01, settings = emptyMap(), recording = null),
            ),
        )
        val cameras = listOf(dji, silent)
        val a = entry("A", dji)
        val b = entry("B", silent)
        val g = group(listOf(a, b))
        val live = state(cameras)
        val strict = RecordPlan.make(START, STRICT, listOf(a.id, b.id), g, live)
        assertTrue(strict.isRefused)
        assertEquals(
            listOf(Exclusion(b.id, ExclusionReason.Rejected(CommandRejection.RecordingStateUnknown))),
            strict.exclusions,
        )
        val subset = RecordPlan.make(START, ELIGIBLE_SUBSET, listOf(a.id, b.id), g, live)
        assertEquals(listOf(dji.id), subset.targets.map { it.session })
        subset.submit(g, live, sessions(cameras))
        assertTrue(silent.wire.isEmpty())
    }
}
