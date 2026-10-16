package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import androidx.core.content.edit

/**
 * The operator's camera-motion choices under the app's existing keys, defaults and ranges. Enum
 * interpretation stays with the host: curve, size, ramp and double-tap are stored raw so an unknown
 * value written by a newer build survives. Reads never write; ranged values clamp on read and write.
 */
public class MonitorMotionPreferences(
    private val storage: SharedPreferences,
    private val keys: Keys,
    private val defaults: Defaults,
    private val limits: Limits,
) {
    public data class Keys(
        public val headTrackingEnabled: String,
        public val gimbalStickSensitivity: String,
        public val virtualJoystickInvertPan: String,
        public val virtualJoystickInvertTilt: String,
        public val virtualJoystickDeadzonePercent: String,
        public val virtualJoystickResponseCurve: String,
        public val virtualJoystickSize: String,
        public val gimbalRamp: String,
        public val gimbalDoubleTap: String,
    ) {
        init {
            val names = listOf(headTrackingEnabled, gimbalStickSensitivity, virtualJoystickInvertPan,
                virtualJoystickInvertTilt, virtualJoystickDeadzonePercent, virtualJoystickResponseCurve,
                virtualJoystickSize, gimbalRamp, gimbalDoubleTap)
            require(names.all { it.isNotEmpty() } && names.toSet().size == names.size)
        }

        public companion object {
            /** The keys camera apps already use: `<prefix>HeadTrackingEnabled` and so on. */
            public fun prefixed(prefix: String): Keys = Keys(
                "${prefix}HeadTrackingEnabled", "${prefix}GimbalStickSensitivity",
                "${prefix}VirtualJoystickInvertPan", "${prefix}VirtualJoystickInvertTilt",
                "${prefix}VirtualJoystickDeadzonePercent", "${prefix}VirtualJoystickResponseCurve",
                "${prefix}VirtualJoystickSize", "${prefix}GimbalRamp", "${prefix}GimbalDoubleTap",
            )
        }
    }

    public data class Defaults(
        public val gimbalStickSensitivity: Int,
        public val virtualJoystickDeadzonePercent: Int,
        public val virtualJoystickResponseCurve: String,
        public val virtualJoystickSize: String,
        public val gimbalRamp: Int,
        public val gimbalDoubleTap: Int,
        public val headTrackingEnabled: Boolean = false,
        public val virtualJoystickInvertPan: Boolean = false,
        public val virtualJoystickInvertTilt: Boolean = false,
    )

    public data class Limits(public val sensitivity: IntRange, public val deadzonePercent: IntRange) {
        init { require(!sensitivity.isEmpty() && !deadzonePercent.isEmpty()) }
    }

    public var headTrackingEnabled: Boolean
        get() = storage.getBoolean(keys.headTrackingEnabled, defaults.headTrackingEnabled)
        set(value) = storage.edit { putBoolean(keys.headTrackingEnabled, value) }
    public var gimbalStickSensitivity: Int
        get() = storage.getInt(keys.gimbalStickSensitivity, defaults.gimbalStickSensitivity).coerceIn(limits.sensitivity)
        set(value) = storage.edit { putInt(keys.gimbalStickSensitivity, value.coerceIn(limits.sensitivity)) }
    public var virtualJoystickInvertPan: Boolean
        get() = storage.getBoolean(keys.virtualJoystickInvertPan, defaults.virtualJoystickInvertPan)
        set(value) = storage.edit { putBoolean(keys.virtualJoystickInvertPan, value) }
    public var virtualJoystickInvertTilt: Boolean
        get() = storage.getBoolean(keys.virtualJoystickInvertTilt, defaults.virtualJoystickInvertTilt)
        set(value) = storage.edit { putBoolean(keys.virtualJoystickInvertTilt, value) }
    public var virtualJoystickDeadzonePercent: Int
        get() = storage.getInt(keys.virtualJoystickDeadzonePercent, defaults.virtualJoystickDeadzonePercent)
            .coerceIn(limits.deadzonePercent)
        set(value) = storage.edit {
            putInt(keys.virtualJoystickDeadzonePercent, value.coerceIn(limits.deadzonePercent))
        }
    public var virtualJoystickResponseCurve: String
        get() = storage.getString(keys.virtualJoystickResponseCurve, null) ?: defaults.virtualJoystickResponseCurve
        set(value) = storage.edit { putString(keys.virtualJoystickResponseCurve, value) }
    public var virtualJoystickSize: String
        get() = storage.getString(keys.virtualJoystickSize, null) ?: defaults.virtualJoystickSize
        set(value) = storage.edit { putString(keys.virtualJoystickSize, value) }
    public var gimbalRamp: Int
        get() = storage.getInt(keys.gimbalRamp, defaults.gimbalRamp)
        set(value) = storage.edit { putInt(keys.gimbalRamp, value) }
    public var gimbalDoubleTap: Int
        get() = storage.getInt(keys.gimbalDoubleTap, defaults.gimbalDoubleTap)
        set(value) = storage.edit { putInt(keys.gimbalDoubleTap, value) }
}
