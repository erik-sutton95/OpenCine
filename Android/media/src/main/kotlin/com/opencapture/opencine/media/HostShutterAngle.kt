package com.opencapture.opencine.media

import com.opencapture.opencine.core.Rational
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

    /** Relative distance within which a readback exposure is the 1/N it rounds to. */
    const val SPEED_SNAP_TOLERANCE: Double = 0.005

    /**
     * A camera's exposure-time readback in seconds as a duration. Cameras store it as a float that
     * is not always bit-exact (a single-precision 1/60 reads 1/59.99999), so a readback within
     * 0.5 % of 1/N is that speed, as the pre-shared apps rounded it; whole seconds stay whole and
     * anything else keeps microseconds. Owner 2026-10-20 (Luna, Angle 180 at 30p): a microsecond
     * remainder whose denominator was read as the speed showed 0.0108 degrees. Swift twin.
     */
    fun readback(seconds: Double): Rational? {
        if (!seconds.isFinite() || seconds <= 0 || seconds >= Int.MAX_VALUE.toDouble()) return null
        if (seconds == Math.round(seconds).toDouble()) return Rational(seconds.toInt())
        val reciprocal = 1 / seconds
        if (reciprocal.isFinite() && reciprocal >= 1 && reciprocal < Int.MAX_VALUE.toDouble() &&
            abs(reciprocal - Math.round(reciprocal)) <= reciprocal * SPEED_SNAP_TOLERANCE
        ) return Rational(1, Math.round(reciprocal).toInt())
        val scaled = Math.round(seconds * 1_000_000).toDouble()
        if (scaled < 1 || scaled >= Int.MAX_VALUE.toDouble()) return null
        return Rational(scaled.toInt(), 1_000_000)
    }

    /**
     * The angle an exposure time makes at the reported cadence, from the whole duration: a
     * measured readback may not be 1/N, so its denominator alone is not a speed.
     */
    fun reported(seconds: Rational, framesPerSecond: Double?): Double? {
        if (seconds.numerator <= 0 || seconds.denominator <= 0 || framesPerSecond == null ||
            !framesPerSecond.isFinite() || framesPerSecond <= 0) return null
        return (360 * framesPerSecond * seconds.doubleValue).takeIf { it.isFinite() }
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
