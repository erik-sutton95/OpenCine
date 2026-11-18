package com.opencapture.opencine.appkit

import kotlin.test.*

/** The interface lock holds the screen's rotation. Swift twin: `MonitorRotationHoldTests`. */
class MonitorRotationHoldTest {
    private enum class Turn { PORTRAIT, LANDSCAPE, INVERTED_LANDSCAPE }

    @Test fun lockHoldsTheOrientationItEngagedInThroughLaterTurnsAndUnlockReleasesIt() {
        val hold = MonitorRotationHold<Turn>()
        assertFalse(hold.update(false, Turn.LANDSCAPE))
        assertNull(hold.held)
        // An inverted rig: the lock engages upside down and keeps it while the phone is levelled.
        assertTrue(hold.update(true, Turn.INVERTED_LANDSCAPE))
        assertEquals(Turn.INVERTED_LANDSCAPE, hold.held)
        assertFalse(hold.update(true, Turn.LANDSCAPE))
        assertFalse(hold.update(true, Turn.PORTRAIT))
        assertEquals(Turn.INVERTED_LANDSCAPE, hold.held)
        assertTrue(hold.update(false, Turn.PORTRAIT))
        assertNull(hold.held)
        assertFalse(hold.update(false, Turn.LANDSCAPE))
    }

    @Test fun lockEngagedWhileTheOrientationIsUnknownHoldsTheFirstKnownOne() {
        val hold = MonitorRotationHold<Turn>()
        assertFalse(hold.update(true, null))
        assertNull(hold.held)
        assertTrue(hold.update(true, Turn.LANDSCAPE))
        assertFalse(hold.update(true, null))
        assertEquals(Turn.LANDSCAPE, hold.held)
    }

    @Test fun relockingCapturesTheNewOrientation() {
        val hold = MonitorRotationHold<Turn>()
        hold.update(true, Turn.LANDSCAPE)
        hold.update(false, Turn.LANDSCAPE)
        assertTrue(hold.update(true, Turn.INVERTED_LANDSCAPE))
        assertEquals(Turn.INVERTED_LANDSCAPE, hold.held)
    }
}
