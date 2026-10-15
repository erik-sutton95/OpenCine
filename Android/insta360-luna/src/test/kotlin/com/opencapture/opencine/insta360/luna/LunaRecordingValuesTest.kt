package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.insta360.shell.CameraColorProfile
import com.opencapture.opencine.insta360.shell.CameraRecordFormat
import com.opencapture.opencine.insta360.shell.aspectLabel
import com.opencapture.opencine.insta360.shell.label
import com.opencapture.opencine.insta360.shell.nativeRecordingColorProfiles
import kotlin.test.Test
import kotlin.test.assertEquals

/** The colour names and shape groups every Luna host shows (twin of Swift LunaRecordingValuesTests). */
class LunaRecordingValuesTest {
    @Test fun colourNamesAndNativeChoicesAreShared() {
        assertEquals(listOf("Standard", "I-Log", "Dolby Vision"), nativeRecordingColorProfiles.map { it.label })
        assertEquals("Vivid", CameraColorProfile.VIVID.label)
        assertEquals("HDR", CameraColorProfile.HDR.label)
    }

    @Test fun formatsGroupByTheirSharedShape() {
        assertEquals("16:9", CameraRecordFormat(48, 3840, 2160, 25.0).aspectLabel)
        assertEquals("16:9", CameraRecordFormat(1, 2720, 1530, 25.0).aspectLabel)
        assertEquals("9:16", CameraRecordFormat(2, 1728, 3072, 25.0).aspectLabel)
        assertEquals("?", CameraRecordFormat(3, 1920, 0, 25.0).aspectLabel)
    }
}
