package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Scenario names mirror the existing Swift ShutterAngleTests. */
class ShutterAngleTest {
    @Test fun ladderRunsFromFivePointSixToThreeSixty() {
        assertEquals(5.6, ShutterAngle.degrees.first())
        assertEquals(360.0, ShutterAngle.degrees.last())
        assertEquals("180°", ShutterAngle.label(180.0))
        assertEquals("5.6°", ShutterAngle.labels.first())
        assertEquals(172.0, ShutterAngle.parse("172°"))
        assertNull(ShutterAngle.parse("0°"))
    }

    @Test fun oneEightyIsAHalfTurnAtAnyFps() {
        for (fps in listOf(24, 25, 30, 50, 60, 120)) {
            assertEquals(fps * 2, ShutterAngle.denom(180.0, fps))
            assertEquals(180.0, ShutterAngle.degrees(fps * 2, fps))
        }
    }

    @Test fun liveSpeedSnapsToTheNearestStop() {
        assertEquals("172°", ShutterAngle.nearestLabel(50, 24))
        assertEquals("144°", ShutterAngle.nearestLabel(60, 24))
    }

    @Test fun unknownShutterOrRateHasNoAngle() {
        for ((denom, fps) in listOf(0 to 24, -1 to 24, 48 to 0, 48 to 7, 48 to 241)) {
            assertNull(ShutterAngle.degrees(denom, fps))
            assertNull(ShutterAngle.nearestLabel(denom, fps))
        }
        assertEquals(48, ShutterAngle.denom(180.0, 0))
    }

    @Test fun sendSnapsToTheCameraList() {
        assertEquals(50, ShutterAngle.denom(180.0, 24, listOf(50, 60, 100)))
        assertEquals(48, ShutterAngle.denom(180.0, 24, emptyList()))
        assertEquals(48, ShutterAngle.denom(180.0, 24, listOf(48, 52)))
        assertEquals(48, ShutterAngle.denom(180.0, 25, listOf(48, 52)))
    }

    @Test fun formatRematchRequiresEstablishedManualVideoAndPreservesQueuedIntent() {
        assertTrue(ShutterAngle.rematchesFormat(true, true, false, 24, 30))
        assertTrue(ShutterAngle.rematchesFormat(true, true, false, 24, 24, true))
        assertFalse(ShutterAngle.rematchesFormat(true, false, false, 24, 30))
        assertFalse(ShutterAngle.rematchesFormat(true, true, true, 24, 30))
        assertFalse(ShutterAngle.rematchesFormat(true, true, false, 0, 30))
    }
}
