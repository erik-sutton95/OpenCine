package com.opencapture.opencine.vocabulary

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CaptureLadderTest {
    @Test
    fun recordingAndCameraControlFreezeTheSheet() {
        assertTrue(CaptureLock.RECORDING.freezesSheet)
        assertTrue(CaptureLock.CAMERA_CONTROL.freezesSheet)
        assertFalse(CaptureLock.AUTO.freezesSheet)
        assertFalse(CaptureLock.EXPOSURE_PROGRAM.freezesSheet)
    }

    @Test
    fun anUnknownCurrentAndAnOpenLockStayNull() {
        val ladder = CaptureLadder(current = null, values = listOf("Wide"))
        assertNull(ladder.current)
        assertNull(ladder.lock)
        assertEquals(emptySet(), ladder.marked)
    }

    @Test
    fun aTintMayOmitTheAmberBlueAxis() {
        val tint = CaptureTint(greenMagenta = 2, amberBlue = null, range = -6..6)
        assertNull(tint.amberBlue)
        assertEquals(2, tint.greenMagenta)
    }
}
