package com.opencapture.opencine.gyro

import android.content.SharedPreferences
import org.json.JSONObject

/**
 * Namespaced keys for the gyro preferences this module owns.
 *
 * @property enabled whether gyro logging is enabled.
 * @property calibrations per-camera calibrations, stored as one JSON object keyed by camera id.
 * @property pendingRestores stabilization restores the app still owes.
 * @property tipDismissed whether the logs tip was dismissed.
 * @property legacyCalibration a legacy global calibration waiting for the first camera id that asks.
 * @property migrated set once the legacy migration ran.
 */
data class GyroPreferenceKeys(
    val enabled: String,
    val calibrations: String,
    val pendingRestores: String,
    val tipDismissed: String,
    val legacyCalibration: String,
    val migrated: String,
) {
    companion object {
        /** Builds the key set under a host prefix, for example an app namespace. */
        fun namespaced(prefix: String): GyroPreferenceKeys =
            GyroPreferenceKeys(
                enabled = prefix + "enabled",
                calibrations = prefix + "calibrations",
                pendingRestores = prefix + "pendingRestores",
                tipDismissed = prefix + "tipDismissed",
                legacyCalibration = prefix + "legacyCalibration",
                migrated = prefix + "migrated",
            )
    }
}

/**
 * Old app-wide keys read once when calibrations became per-camera.
 *
 * @property enabled old app-wide enabled flag, copied and left in place.
 * @property mountPreset old manual mount preset, dropped when presets became not calibrated.
 * @property calibration old global calibration, adopted by the first camera that has none.
 */
data class GyroLegacyPreferenceKeys(
    val enabled: String,
    val mountPreset: String,
    val calibration: String,
)

/**
 * Host-persisted gyro preferences: the toggle, the logs tip, per-camera calibrations and the
 * stabilization restores the app still owes. Twin of OpenCineGyro's GyroPreferences; booleans are
 * SharedPreferences booleans and a calibration is one JSON object string keyed by camera id.
 */
class GyroPreferences(
    private val prefs: SharedPreferences,
    private val keys: GyroPreferenceKeys,
    legacy: GyroLegacyPreferenceKeys? = null,
    private val native: GyroNativeApi = GyroNative,
) {
    init {
        if (legacy != null && !prefs.contains(keys.migrated)) migrate(legacy)
    }

    /** Whether gyro logging is enabled; false by default. */
    var enabled: Boolean
        get() = prefs.getBoolean(keys.enabled, false)
        set(value) {
            prefs.edit().putBoolean(keys.enabled, value).apply()
        }

    /** Whether the logs tip was dismissed; false by default. */
    var tipDismissed: Boolean
        get() = prefs.getBoolean(keys.tipDismissed, false)
        set(value) {
            prefs.edit().putBoolean(keys.tipDismissed, value).apply()
        }

    /**
     * Stabilization restores the app still owes, as the JSON string the arming wire gave it.
     * Setting it commits synchronously (call off the main thread) and throws when the write fails.
     */
    var pendingRestoresJSON: String
        get() = prefs.getString(keys.pendingRestores, "[]") ?: "[]"
        set(value) {
            // Committed synchronously: the IBIS-off write follows immediately, and a restore
            // lost to a process kill would leave the camera's stabilization off for good.
            check(prefs.edit().putString(keys.pendingRestores, value).commit()) {
                "Could not save the owed stabilization restore."
            }
        }

    /** Returns the saved calibration for a camera, adopting a valid legacy one once. */
    fun calibrationJSON(cameraId: String): String? {
        val calibrations = calibrationObject()
        if (calibrations.has(cameraId)) {
            val json = calibrations.optJSONObject(cameraId)?.toString()
            if (json != null && native.calibrationValidate(json)) return json
            calibrations.remove(cameraId)
            writeCalibrations(calibrations)
            return null
        }
        val legacyCalibration = prefs.getString(keys.legacyCalibration, null) ?: return null
        prefs.edit().remove(keys.legacyCalibration).apply()
        if (!native.calibrationValidate(legacyCalibration)) return null
        val parsed = runCatching { JSONObject(legacyCalibration) }.getOrNull() ?: return null
        calibrations.put(cameraId, parsed)
        writeCalibrations(calibrations)
        return parsed.toString()
    }

    /**
     * Stores a calibration for one camera id, keeping the other cameras' calibrations. Committed
     * synchronously (call off the main thread); throws when the write fails.
     */
    fun saveCalibration(cameraId: String, json: String) {
        val calibrations = calibrationObject()
        calibrations.put(cameraId, JSONObject(json))
        check(prefs.edit().putString(keys.calibrations, calibrations.toString()).commit()) {
            "Could not save the calibration."
        }
    }

    private fun migrate(legacy: GyroLegacyPreferenceKeys) {
        if (prefs.contains(legacy.enabled)) {
            prefs.edit().putBoolean(keys.enabled, prefs.getBoolean(legacy.enabled, false)).apply()
        }
        prefs.edit().remove(legacy.mountPreset).apply()
        val calibration = prefs.getString(legacy.calibration, null)
        if (calibration != null) {
            prefs.edit().remove(legacy.calibration).apply()
            if (native.calibrationValidate(calibration)) {
                prefs.edit().putString(keys.legacyCalibration, calibration).apply()
            }
        }
        prefs.edit().putBoolean(keys.migrated, true).apply()
    }

    private fun calibrationObject(): JSONObject =
        prefs.getString(keys.calibrations, null)?.let {
            runCatching { JSONObject(it) }.getOrNull()
        } ?: JSONObject()

    private fun writeCalibrations(calibrations: JSONObject) {
        prefs.edit().putString(keys.calibrations, calibrations.toString()).apply()
    }
}
