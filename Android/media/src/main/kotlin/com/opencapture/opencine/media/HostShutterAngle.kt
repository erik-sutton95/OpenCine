package com.opencapture.opencine.media

import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import kotlin.math.abs
import kotlin.math.floor

public enum class HostShutterPresentation { CAMERA_VALUE, EMULATED_ANGLE }

/** Conversion uses reported cadence only; unknown cadence never becomes a default-rate write. */
public object HostShutterAngle {
    val choices: List<SettingValue> get() = ShutterAngle.degrees.map { SettingValue.Shutter(ShutterValue.Angle(it)) }

    fun reported(denominator: Int, framesPerSecond: Double?): Double? {
        if (denominator <= 0 || framesPerSecond == null || !framesPerSecond.isFinite() || framesPerSecond <= 0) return null
        return (360 * framesPerSecond / denominator).takeIf { it.isFinite() }
    }

    fun denominator(degrees: Double, framesPerSecond: Double?, available: List<Int>): Int? {
        if (!degrees.isFinite() || degrees <= 0 || degrees > 360 || framesPerSecond == null || !framesPerSecond.isFinite() || framesPerSecond <= 0) return null
        val native = available.filter { it in 1..16_000 }
        if (native.isEmpty()) return null
        val raw = 360 * framesPerSecond / degrees
        if (!raw.isFinite()) return null
        val ideal = floor(raw + 0.5).coerceIn(1.0, 16_000.0).toInt()
        return native.minByOrNull { abs(it - ideal) }
    }
}
