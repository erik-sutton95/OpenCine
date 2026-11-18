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
    @Test fun settingsCategoriesFollowTheCamerasCapabilitiesInIOSOrder() {
        val c = MultiviewSettingsCategory
        assertEquals(
            listOf(MultiviewSettingsCategory.ISO, MultiviewSettingsCategory.SHUTTER, MultiviewSettingsCategory.EXPOSURE,
                MultiviewSettingsCategory.WB, MultiviewSettingsCategory.FOCUS, MultiviewSettingsCategory.MODE,
                MultiviewSettingsCategory.RESOLUTION, MultiviewSettingsCategory.COLOR, MultiviewSettingsCategory.AUDIO),
            c.offered(focus = true, aperture = false, photo = false, audio = true),
        )
        assertEquals(
            listOf(MultiviewSettingsCategory.ISO, MultiviewSettingsCategory.SHUTTER, MultiviewSettingsCategory.EXPOSURE,
                MultiviewSettingsCategory.WB, MultiviewSettingsCategory.APERTURE, MultiviewSettingsCategory.MODE,
                MultiviewSettingsCategory.RESOLUTION, MultiviewSettingsCategory.COLOR),
            c.offered(focus = false, aperture = true, photo = false, audio = false),
        )
        assertEquals(
            listOf(MultiviewSettingsCategory.ISO, MultiviewSettingsCategory.SHUTTER, MultiviewSettingsCategory.EXPOSURE,
                MultiviewSettingsCategory.WB, MultiviewSettingsCategory.FOCUS, MultiviewSettingsCategory.APERTURE,
                MultiviewSettingsCategory.MODE),
            c.offered(focus = true, aperture = true, photo = true, audio = true),
            "a photo mode offers no format, color or audio",
        )
        assertEquals(
            listOf("Iso", "Shutter", "Exposure", "WB", "Focus", "Aperture", "Mode", "Format", "Color", "Audio"),
            MultiviewSettingsCategory.entries.map { it.title },
        )
        assertEquals("multiview.settings.control.wb", MultiviewSettingsCategory.WB.identifier)
    }

    @Test fun recordingLocksModeFormatAndColor() {
        for (category in MultiviewSettingsCategory.entries) {
            assertFalse(category.locked(recording = false))
            assertEquals(
                category in listOf(MultiviewSettingsCategory.MODE, MultiviewSettingsCategory.RESOLUTION,
                    MultiviewSettingsCategory.COLOR),
                category.locked(recording = true),
            )
        }
    }

    @Test fun closeCopyFollowsWhetherCamerasReturn() {
        assertEquals("Returning cameras to their Wi-Fi\u2026", MultiviewNetworkRestore.CAMERA_NETWORKS.closingProgress)
        assertEquals("Closing Multiview\u2026", MultiviewNetworkRestore.NONE.closingProgress)
        assertEquals(
            "Each camera will join Studio. Approve on the camera if asked.",
            MultiviewCopy.pickerFooter("Studio", commissioned = true),
        )
        assertEquals(
            "Each camera will join Studio.",
            MultiviewCopy.pickerFooter("Studio", commissioned = true, asksApproval = false),
        )
        assertEquals("Cameras already on Studio appear here.", MultiviewCopy.pickerFooter("Studio", commissioned = false))
        assertEquals(
            "Cameras on this phone\u2019s network appear here.",
            MultiviewCopy.pickerFooter("", commissioned = false),
        )
    }

    @Test fun theScreenToolbarKeepsIOSOrder() {
        assertEquals(
            listOf(MultiviewTool.LAYOUT, MultiviewTool.CAMERA, MultiviewTool.FIT, MultiviewTool.LUT),
            MultiviewTool.SCREEN,
        )
    }
}
