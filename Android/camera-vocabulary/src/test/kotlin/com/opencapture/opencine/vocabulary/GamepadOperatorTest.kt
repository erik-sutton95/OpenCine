package com.opencapture.opencine.vocabulary

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class GamepadOperatorTest {
    /** Owner 2026-10-20: "42°" flashed during a 4K30/4K120 change. Swift twin. */
    @Test fun shutterHudHoldsThePreferredAngleWhileSettling() {
        val luna = listOf(1000, 500, 250, 125, 60, 50)
        assertEquals("45°", GamepadShutterSync.angleLabel(250, 30, luna, 180.0))
        assertEquals("180°", GamepadShutterSync.angleLabel(250, 30, luna, 180.0, settling = true))
        assertEquals("180°", GamepadShutterSync.angleLabel(60, 120, luna, 180.0, settling = true))
        assertEquals("180°", GamepadShutterSync.angleLabel(250, 120, luna, 180.0))
    }

    @Test
    fun gimbalStickDefaultsLeftAndIgnoresTheOtherAxes() {
        assertEquals(GamepadGimbalStick.DEFAULT, GamepadGimbalStick.LEFT)
        assertEquals(GamepadGimbalStick.LEFT, GamepadGimbalStick.parse(null))
        assertEquals(GamepadGimbalStick.RIGHT, GamepadGimbalStick.parse("right"))
        val left = GamepadGimbalStick.LEFT.axes(0.8f, -0.2f, -1f, 1f)
        assertEquals(0.8f, left.first)
        assertEquals(-0.2f, left.second)
        val right = GamepadGimbalStick.RIGHT.axes(0.8f, -0.2f, -1f, 1f)
        assertEquals(-1f, right.first)
        assertEquals(1f, right.second)
        assertTrue(GamepadGimbalStick.restHeldMotion(GamepadGimbalStick.LEFT, GamepadGimbalStick.RIGHT, true))
        assertFalse(GamepadGimbalStick.restHeldMotion(GamepadGimbalStick.LEFT, GamepadGimbalStick.LEFT, true))
        assertFalse(GamepadGimbalStick.restHeldMotion(GamepadGimbalStick.LEFT, GamepadGimbalStick.RIGHT, false))
    }

    @Test
    fun shutterHudUsesLiveDenomWhenPreferredDoesNotMap() {
        val available = listOf(24, 48, 50, 60, 120)
        assertEquals(
            "180°",
            GamepadShutterSync.angleLabel(48, 24, available, 180.0),
        )
        assertEquals(
            "72°",
            GamepadShutterSync.angleLabel(120, 24, available, 180.0),
        )
        assertTrue(GamepadShutterSync.shouldPersistPreferredAngle(true, false, false))
        assertFalse(GamepadShutterSync.shouldPersistPreferredAngle(true, true, false))
        assertFalse(GamepadShutterSync.shouldPersistPreferredAngle(true, false, true))
        val speedStops = listOf(16000, 120, 60, 50, 48, 24)
        val synced = GamepadShutterSync.preferredAngle(50, 24)
        assertEquals(172.0, synced)
        assertEquals("172°", GamepadShutterSync.angleLabel(50, 24, speedStops, synced))
        assertTrue(ShutterAngle.denom(synced, 60) != ShutterAngle.denom(180.0, 60))
    }

    @Test
    fun outOfRangeRateAndUnknownDenomKeepTheFallbacks() {
        assertEquals(180.0, GamepadShutterSync.preferredAngle(0, 24))
        assertEquals(GamepadShutterSync.preferredAngle(48, 24), GamepadShutterSync.preferredAngle(48, 0))
        assertEquals("180°", GamepadShutterSync.angleLabel(48, 0, listOf(24, 60), 90.0))
    }
}
