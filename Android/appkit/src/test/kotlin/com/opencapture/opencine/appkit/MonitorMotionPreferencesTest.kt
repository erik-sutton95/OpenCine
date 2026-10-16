package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MonitorMotionPreferencesTest {
    @Test fun existingMotionChoicesKeepTheirKeysDefaultsAndUnknownRawValues() {
        for (prefix in listOf("OpenPocketCine", "OpenInstaCine")) {
            val memory = MotionPreferencesMemory()
            val keys = MonitorMotionPreferences.Keys(
                "$prefix.HeadTrackingEnabled", "$prefix.GimbalStickSensitivity",
                "$prefix.VirtualJoystickInvertPan", "$prefix.VirtualJoystickInvertTilt",
                "$prefix.VirtualJoystickDeadzonePercent", "$prefix.VirtualJoystickResponseCurve",
                "$prefix.VirtualJoystickSize", "$prefix.GimbalRamp", "$prefix.GimbalDoubleTap",
            )
            val store = MonitorMotionPreferences(memory.storage, keys,
                MonitorMotionPreferences.Defaults(4, 8, "standard", "medium", 0, 0),
                MonitorMotionPreferences.Limits(1..5, 0..25))
            assertFalse(store.headTrackingEnabled)
            assertEquals(4, store.gimbalStickSensitivity)
            assertFalse(store.virtualJoystickInvertPan || store.virtualJoystickInvertTilt)
            assertEquals(8, store.virtualJoystickDeadzonePercent)
            assertEquals("standard", store.virtualJoystickResponseCurve)
            assertEquals("medium", store.virtualJoystickSize)
            assertEquals(0, store.gimbalRamp)
            assertEquals(0, store.gimbalDoubleTap)
            assertTrue(memory.values.isEmpty())

            memory.values.putAll(mapOf(
                "$prefix.HeadTrackingEnabled" to false, "$prefix.VirtualJoystickInvertPan" to false,
                "$prefix.VirtualJoystickInvertTilt" to true, "$prefix.GimbalStickSensitivity" to 99,
                "$prefix.VirtualJoystickDeadzonePercent" to -4, "$prefix.VirtualJoystickResponseCurve" to "future-curve",
                "$prefix.VirtualJoystickSize" to "future-size", "$prefix.GimbalRamp" to 99, "$prefix.GimbalDoubleTap" to 99,
            ))
            val original = memory.values.toMap()
            assertFalse(store.headTrackingEnabled || store.virtualJoystickInvertPan)
            assertTrue(store.virtualJoystickInvertTilt)
            assertEquals(5, store.gimbalStickSensitivity)
            assertEquals(0, store.virtualJoystickDeadzonePercent)
            assertEquals("future-curve", store.virtualJoystickResponseCurve)
            assertEquals("future-size", store.virtualJoystickSize)
            assertEquals(99, store.gimbalRamp)
            assertEquals(99, store.gimbalDoubleTap)
            assertEquals(original, memory.values)
        }
    }

    @Test fun writesClampRangesKeepRawValuesAndUseTheExistingKeys() {
        val memory = MotionPreferencesMemory()
        val store = MonitorMotionPreferences(memory.storage, MonitorMotionPreferences.Keys.prefixed("OpenPocketCine."),
            MonitorMotionPreferences.Defaults(4, 8, "standard", "medium", 0, 0),
            MonitorMotionPreferences.Limits(1..5, 0..25))
        store.gimbalStickSensitivity = 0
        store.virtualJoystickDeadzonePercent = 40
        store.headTrackingEnabled = true
        store.virtualJoystickInvertPan = true
        store.virtualJoystickResponseCurve = "smooth"
        store.virtualJoystickSize = "large"
        store.gimbalRamp = 2
        store.gimbalDoubleTap = 1
        assertEquals(mapOf<String, Any>(
            "OpenPocketCine.GimbalStickSensitivity" to 1, "OpenPocketCine.VirtualJoystickDeadzonePercent" to 25,
            "OpenPocketCine.HeadTrackingEnabled" to true, "OpenPocketCine.VirtualJoystickInvertPan" to true,
            "OpenPocketCine.VirtualJoystickResponseCurve" to "smooth", "OpenPocketCine.VirtualJoystickSize" to "large",
            "OpenPocketCine.GimbalRamp" to 2, "OpenPocketCine.GimbalDoubleTap" to 1,
        ), memory.values)
    }

    @Test fun sharingChoicesKeepTheirKeysDefaultsAndClamp() {
        for (prefix in listOf("OpenPocketCine.", "OpenInstaCine.")) {
            val memory = MotionPreferencesMemory()
            val store = MonitorSharingPreferences(memory.storage, MonitorSharingPreferences.Keys.prefixed(prefix), 0..3)
            assertFalse(store.shareThisFeed)
            assertTrue(store.controlRequests)
            assertEquals(0, store.broadcastPriority)
            assertTrue(memory.values.isEmpty())
            memory.values.putAll(mapOf("${prefix}ControlRequests" to false, "${prefix}ShareThisFeed" to true,
                "${prefix}BroadcastPriority" to 9))
            assertTrue(store.shareThisFeed)
            assertFalse(store.controlRequests)
            assertEquals(3, store.broadcastPriority)
            store.broadcastPriority = -2
            assertEquals(0, memory.values["${prefix}BroadcastPriority"])
        }
    }
}

private class MotionPreferencesMemory {
    val values = mutableMapOf<String, Any>()
    val storage: SharedPreferences = Proxy.newProxyInstance(
        SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java),
    ) { _, method, arguments ->
        when (method.name) {
            "contains" -> values.containsKey(arguments!![0] as String)
            "getBoolean", "getInt", "getString" -> values[arguments!![0] as String] ?: arguments[1]
            "edit" -> editor()
            else -> error("Unexpected preferences call: ${method.name}")
        }
    } as SharedPreferences

    private fun editor(): SharedPreferences.Editor = Proxy.newProxyInstance(
        SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java),
    ) { proxy, method, arguments ->
        when (method.name) {
            "putBoolean", "putInt", "putString" -> { values[arguments!![0] as String] = arguments[1]!!; proxy }
            "apply" -> null
            else -> error("Unexpected editor call: ${method.name}")
        }
    } as SharedPreferences.Editor
}
