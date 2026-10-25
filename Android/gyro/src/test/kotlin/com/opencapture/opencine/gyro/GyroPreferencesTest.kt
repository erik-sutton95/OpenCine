package com.opencapture.opencine.gyro

import android.content.SharedPreferences
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.json.JSONObject

/**
 * The SharedPreferences twin of `OpenCineGyro`'s GyroPreferences: booleans stay booleans,
 * calibrations are one JSON object keyed by camera id, and the old app-wide keys migrate once.
 */
class GyroPreferencesTest {
    private val keys = GyroPreferenceKeys.namespaced("gyro.test.")
    private val legacy =
        GyroLegacyPreferenceKeys(
            enabled = "enabled",
            mountPreset = "mountPreset",
            calibration = "mountCalibration",
        )
    private val firstCalibration =
        """{"rotation":[{"x":1,"y":0,"z":0},{"x":0,"y":1,"z":0},{"x":0,"y":0,"z":1}],"validationErrorDegrees":1.5,"separationDegrees":60}"""
    private val secondCalibration =
        """{"rotation":[{"x":0,"y":1,"z":0},{"x":1,"y":0,"z":0},{"x":0,"y":0,"z":1}],"validationErrorDegrees":2.5,"separationDegrees":45}"""

    @Test
    fun calibrationsPerCamera() {
        assertEquals(
            GyroPreferenceKeys(
                enabled = "gyro.test.enabled",
                calibrations = "gyro.test.calibrations",
                pendingRestores = "gyro.test.pendingRestores",
                tipDismissed = "gyro.test.tipDismissed",
                legacyCalibration = "gyro.test.legacyCalibration",
                migrated = "gyro.test.migrated",
            ),
            keys,
        )
        val prefs = MemoryPreferences()
        val preferences = GyroPreferences(prefs, keys, null, CalibrationNative())
        preferences.saveCalibration("body-1", firstCalibration)
        preferences.saveCalibration("body-2", secondCalibration)
        assertCalibrationEquals(firstCalibration, preferences.calibrationJSON("body-1"))
        assertCalibrationEquals(secondCalibration, preferences.calibrationJSON("body-2"))
        val stored = JSONObject(requireNotNull(prefs.getString(keys.calibrations, null)))
        assertEquals(2, stored.length())
        assertTrue(stored.has("body-1"))
        assertTrue(stored.has("body-2"))
    }

    @Test
    fun pendingRestoresRoundTrip() {
        val prefs = MemoryPreferences()
        val preferences = GyroPreferences(prefs, keys, null, CalibrationNative())
        assertEquals("[]", preferences.pendingRestoresJSON)
        val restores = """[{"cameraID":"body-1","saved":{"ibis":"SPORT"},"applied":{"ibis":"OFF"}}]"""
        preferences.pendingRestoresJSON = restores
        assertEquals(restores, preferences.pendingRestoresJSON)
        assertEquals(
            restores,
            GyroPreferences(prefs, keys, null, CalibrationNative()).pendingRestoresJSON,
        )
    }

    @Test
    fun toggleAndTipPersistAsBooleans() {
        val prefs = MemoryPreferences()
        val preferences = GyroPreferences(prefs, keys, null, CalibrationNative())
        assertFalse(preferences.enabled)
        assertFalse(preferences.tipDismissed)
        preferences.enabled = true
        preferences.tipDismissed = true
        assertTrue(prefs.getBoolean(keys.enabled, false))
        assertTrue(prefs.getBoolean(keys.tipDismissed, false))
        assertTrue(GyroPreferences(prefs, keys, null, CalibrationNative()).enabled)
    }

    @Test
    fun legacyEnabledKeptPresetDropped() {
        val prefs = MemoryPreferences()
        prefs.edit()
            .putBoolean(legacy.enabled, true)
            .putString(legacy.mountPreset, "rearDown")
            .putString(legacy.calibration, "{}")
            .apply()
        val preferences = GyroPreferences(prefs, keys, legacy, CalibrationNative())
        assertTrue(preferences.enabled)
        assertFalse(preferences.tipDismissed)
        assertEquals("[]", preferences.pendingRestoresJSON)
        assertTrue(prefs.getBoolean(legacy.enabled, false))
        assertTrue(prefs.getBoolean(keys.enabled, false))
        assertFalse(prefs.contains(legacy.mountPreset))
        assertFalse(prefs.contains(legacy.calibration))
        assertNull(prefs.getString(keys.legacyCalibration, null))
        assertTrue(prefs.getBoolean(keys.migrated, false))
    }

    @Test
    fun legacyCalibrationAdoptedOnce() {
        val prefs = MemoryPreferences()
        prefs.edit().putString(legacy.calibration, firstCalibration).apply()
        val preferences = GyroPreferences(prefs, keys, legacy, CalibrationNative())
        assertEquals(firstCalibration, prefs.getString(keys.legacyCalibration, null))
        assertFalse(prefs.contains(legacy.calibration))
        assertCalibrationEquals(firstCalibration, preferences.calibrationJSON("body-1"))
        assertNull(prefs.getString(keys.legacyCalibration, null))
        assertNull(preferences.calibrationJSON("body-2"))
        assertCalibrationEquals(firstCalibration, preferences.calibrationJSON("body-1"))
    }

    @Test
    fun migrationRunsOnce() {
        val prefs = MemoryPreferences()
        prefs.edit().putBoolean(legacy.enabled, true).apply()
        GyroPreferences(prefs, keys, legacy, CalibrationNative())
        prefs.edit()
            .putBoolean(keys.enabled, false)
            .putBoolean(legacy.enabled, false)
            .putString(legacy.calibration, firstCalibration)
            .apply()
        val preferences = GyroPreferences(prefs, keys, legacy, CalibrationNative())
        assertFalse(preferences.enabled)
        assertTrue(prefs.contains(legacy.calibration))
        assertNull(prefs.getString(keys.legacyCalibration, null))
        assertTrue(prefs.getBoolean(keys.migrated, false))
    }

    @Test
    fun invalidLegacyCalibrationDropped() {
        val prefs = MemoryPreferences()
        prefs.edit()
            .putString(legacy.calibration, """{"rotation":[]}""")
            .putString(legacy.mountPreset, "rearDown")
            .apply()
        val preferences = GyroPreferences(prefs, keys, legacy, CalibrationNative())
        assertFalse(prefs.contains(legacy.calibration))
        assertNull(prefs.getString(keys.legacyCalibration, null))
        assertNull(preferences.calibrationJSON("body-1"))
    }

    @Test
    fun corruptStoredCalibrationIsDropped() {
        val prefs = MemoryPreferences()
        val preferences = GyroPreferences(prefs, keys, null, CalibrationNative())
        preferences.saveCalibration("body-1", """{"rotation":[]}""")
        assertNull(preferences.calibrationJSON("body-1"))
        assertEquals(
            0,
            JSONObject(requireNotNull(prefs.getString(keys.calibrations, null))).length(),
        )
        preferences.saveCalibration("body-1", firstCalibration)
        assertCalibrationEquals(firstCalibration, preferences.calibrationJSON("body-1"))
    }

    private fun assertCalibrationEquals(expected: String, actual: String?) {
        val expectedJSON = JSONObject(expected)
        val actualJSON = JSONObject(requireNotNull(actual))
        assertEquals(expectedJSON.length(), actualJSON.length())
        assertEquals(
            expectedJSON.getDouble("validationErrorDegrees"),
            actualJSON.getDouble("validationErrorDegrees"),
            0.0,
        )
        assertEquals(
            expectedJSON.getJSONArray("rotation").length(),
            actualJSON.getJSONArray("rotation").length(),
        )
        assertEquals(
            expectedJSON.getDouble("separationDegrees"),
            actualJSON.getDouble("separationDegrees"),
            0.0,
        )
    }

    private inner class CalibrationNative : TestGyroNativeApi() {
        override fun calibrationValidate(calibrationJSON: String): Boolean =
            runCatching { JSONObject(calibrationJSON).getJSONArray("rotation").length() == 3 }
                .getOrDefault(false)
    }

    /** Just enough SharedPreferences for the migrated gyro keys. */
    private class MemoryPreferences(private val values: MutableMap<String, Any?> = mutableMapOf()) :
        SharedPreferences {
        override fun getAll(): Map<String, *> = values.toMap()

        override fun getString(key: String?, defValue: String?): String? =
            values[key] as? String ?: defValue

        override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
            defValues

        override fun getInt(key: String?, defValue: Int): Int = defValue

        override fun getLong(key: String?, defValue: Long): Long = defValue

        override fun getFloat(key: String?, defValue: Float): Float = defValue

        override fun getBoolean(key: String?, defValue: Boolean): Boolean =
            values[key] as? Boolean ?: defValue

        override fun contains(key: String?): Boolean = values.containsKey(key)

        override fun edit(): SharedPreferences.Editor = Editor()

        override fun registerOnSharedPreferenceChangeListener(
            listener: SharedPreferences.OnSharedPreferenceChangeListener?,
        ) = Unit

        override fun unregisterOnSharedPreferenceChangeListener(
            listener: SharedPreferences.OnSharedPreferenceChangeListener?,
        ) = Unit

        private inner class Editor : SharedPreferences.Editor {
            private val puts = mutableMapOf<String, Any?>()
            private val removals = mutableSetOf<String>()

            override fun putString(key: String, value: String?): SharedPreferences.Editor =
                apply { puts[key] = value }

            override fun putStringSet(
                key: String,
                values: MutableSet<String>?,
            ): SharedPreferences.Editor = this

            override fun putInt(key: String, value: Int): SharedPreferences.Editor = this

            override fun putLong(key: String, value: Long): SharedPreferences.Editor = this

            override fun putFloat(key: String, value: Float): SharedPreferences.Editor = this

            override fun putBoolean(key: String, value: Boolean): SharedPreferences.Editor =
                apply { puts[key] = value }

            override fun remove(key: String): SharedPreferences.Editor = apply { removals += key }

            override fun clear(): SharedPreferences.Editor = this

            override fun commit(): Boolean {
                removals.forEach(values::remove)
                values.putAll(puts)
                return true
            }

            override fun apply() {
                commit()
            }
        }
    }
}
