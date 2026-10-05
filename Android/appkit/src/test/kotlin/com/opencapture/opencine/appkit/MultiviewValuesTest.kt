package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.MonitorEntryDescriptor
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.TelemetrySource
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.djiLike
import com.opencapture.opencine.multicam.MulticamGroup
import com.opencapture.opencine.multicam.MulticamSnapshot
import com.opencapture.opencine.multicam.RecordDirection
import com.opencapture.opencine.multicam.RecordPlan
import com.opencapture.opencine.multicam.TargetPolicy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The stage's copy rules. Swift twin: `MultiviewValuesTests`, same names. */
class MultiviewValuesTest {
    @Test fun tallyCopyNeverGuesses() {
        assertEquals(MultiviewTally.UNAVAILABLE, MultiviewTally.text(null))
        assertEquals("STBY", MultiviewTally.text(false))
        assertEquals("REC", MultiviewTally.text(true), "no take length reported")
        assertEquals("REC 01:24", MultiviewTally.text(true, seconds = 84))
        assertEquals("REC 00:00", MultiviewTally.text(true, seconds = -3))
        assertEquals("WAIT", MultiviewTally.text(true, waiting = true, holding = true))
        assertEquals("HOLD", MultiviewTally.text(null, holding = true, failed = true))
        assertEquals("CHECK", MultiviewTally.text(false, failed = true))
        assertEquals(listOf("A", "B", "C", "D", "E"), (0 until 5).map(MultiviewTile::letter))
    }

    @Test fun recordContextExplainsARefusal() {
        val camera = FakeCameraSession.djiLike()
        camera.cameraReportsStatus()
        val entry = MonitorEntryDescriptor(
            name = "A", cameraSession = camera.id, telemetry = TelemetrySource.CAMERA_SESSION,
            controlAuthority = ControlAuthority.Owner,
        )
        val group = MulticamGroup().apply { add(entry) }
        fun plan(state: MulticamSnapshot) = RecordPlan.make(RecordDirection.START, TargetPolicy.STRICT, listOf(entry.id), group, state)
        val ready = plan(MulticamSnapshot(listOf(camera.current), now = MonotonicInstant.ZERO))
        assertTrue(MultiviewRecordContext(ready).canConfirm)
        assertFalse(MultiviewRecordContext(ready, busy = true).canConfirm)
        assertFalse(MultiviewRecordContext(ready, closing = true).canConfirm)
        assertEquals("Start recording?", MultiviewRecordContext(ready).question(single = true))

        val refused = MultiviewRecordContext(
            plan(MulticamSnapshot(listOf(camera.current), busy = setOf(entry.id), now = MonotonicInstant.ZERO)),
        )
        assertTrue(!refused.canConfirm && refused.refusal == "A camera is busy.")
        camera.cameraSwitchesMode(raw = 0x05) // photo
        assertEquals(
            "A camera is not in a video mode.",
            MultiviewRecordContext(plan(MulticamSnapshot(listOf(camera.current), now = MonotonicInstant.ZERO))).refusal,
        )
    }
}
