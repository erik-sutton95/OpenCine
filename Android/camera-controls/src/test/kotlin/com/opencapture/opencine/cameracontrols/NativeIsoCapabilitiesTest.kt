package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.CaptureNativeISOCapabilities
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertNotEquals

class NativeIsoCapabilitiesTest {
    @Test fun absentSupportDoesNotDeclareAnUnsupportedCamera() {
        val value = CaptureNativeISOCapabilities()
        assertNull(value.hop)
        assertNull(value.ceiling)
        assertNotEquals(CaptureNativeISOCapabilities(false, false), value)
    }
    @Test fun anUndeclaredCeilingKeepsAutoWithoutOfferingLimitWrites() {
        val status = CameraStatus(isoIndex = 0, colorMode = CameraCommands.COLOR_NORMAL)
        assertEquals(listOf("Auto"), IsoSheetLogic.autoLabels(status, ceilingSupported = false))
        assertEquals("Auto", IsoSheetLogic.reseat(status, ceilingSupported = false).drumSelection)
        assertNull(IsoSheetLogic.applyDrum("Auto", status, 0, ceilingSupported = false))
        assertEquals(IsoSheetLogic.Command.SetIndex(0),
            IsoSheetLogic.handleModeChange(0, status, ceilingSupported = false).second)
    }
}
