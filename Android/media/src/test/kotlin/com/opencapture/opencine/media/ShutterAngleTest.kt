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

    @Test fun nonFiniteAngleLabelsStayUnknown() {
        for (label in listOf("NaN", "NaN°", "Infinity", "-Infinity", "1e999")) assertNull(ShutterAngle.parse(label))
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

    /** 180 degrees at each rate: the exact 1/N when the body lists it, else the nearest listed. */
    @Test fun oneEightyPerRatePinsTheSpeed() {
        val luna = listOf(8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400,
            320, 250, 200, 160, 125, 100, 80, 60, 50, 40, 30, 25, 15, 10, 5)
        val pocket3 = listOf(8000, 6400, 4000, 3200, 2000, 1600, 1000, 800, 500, 400, 250, 200, 125, 120,
            100, 60, 50, 48, 40, 30, 25, 24)
        for ((fps, exact, onLuna, onPocket3) in listOf(listOf(24, 48, 50, 48), listOf(25, 50, 50, 50),
            listOf(30, 60, 60, 60), listOf(60, 120, 125, 120), listOf(120, 240, 250, 250))) {
            assertEquals(exact, ShutterAngle.denom(180.0, fps))
            assertEquals(onLuna, ShutterAngle.denom(180.0, fps, luna))
            assertEquals(onPocket3, ShutterAngle.denom(180.0, fps, pocket3))
        }
        assertEquals(240, ShutterAngle.denom(180.0, 120, luna + 240))
    }

    @Test fun achievedTellsTheRealAngleOnlyWhenItDiffers() {
        assertEquals("1/250 (172.8°)", ShutterAngle.achieved(180.0, 250, 120))
        assertNull(ShutterAngle.achieved(180.0, 240, 120))
        assertNull(ShutterAngle.achieved(180.0, 60, 30))
        assertNull(ShutterAngle.achieved(180.0, 250, 0))
    }

    /** Owner 2026-10-20 (Luna, Angle 180 at 30p, shutter priority): "0.0108°". Swift twin. */
    @Test fun anInexactReadbackIsItsSpeedAndAngle() {
        for (denom in listOf(48, 50, 60, 120, 125, 240, 250, 1000, 8000)) {
            val inexact = (1.0 / denom).toFloat().toDouble()
            assertEquals(com.opencapture.opencine.core.Rational(1, denom), HostShutterAngle.readback(inexact))
        }
        assertEquals(com.opencapture.opencine.core.Rational(2), HostShutterAngle.readback(2.0))
        assertEquals(com.opencapture.opencine.core.Rational(2, 5), HostShutterAngle.readback(0.4))
        assertNull(HostShutterAngle.readback(0.0))
        assertEquals(com.opencapture.opencine.core.Rational(1, 81), HostShutterAngle.readback(0.0123))
        val measured = com.opencapture.opencine.core.Rational(3, 20)
        assertEquals(measured, HostShutterAngle.readback(0.15))
        assertEquals(180.0, HostShutterAngle.reported(com.opencapture.opencine.core.Rational(1, 60), 30.0))
        assertEquals(270.0, HostShutterAngle.reported(measured, 5.0)!!, 1e-9)
        assertNull(HostShutterAngle.reported(com.opencapture.opencine.core.Rational(1, 60), null))
    }
}
