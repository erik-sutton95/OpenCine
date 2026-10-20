package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.appkit.MonitorCapturePresentation
import com.opencapture.opencine.core.FocusMode
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.vocabulary.GamepadShutterSync
import com.opencapture.opencine.vocabulary.ShutterAngle
import kotlin.math.roundToInt
import com.opencapture.opencine.vocabulary.FocusOption

/** Common reports and coherent native strategy values remain distinct. */
public object CaptureNativeReadoutPresentation {
    /** The measured iris when reported, else the requested aperture strategy, else unknown. */
    public fun aperture(common: Double?, strategy: Int): String =
        common?.let { MonitorCapturePresentation.label(SettingValue.Aperture(it)) }
            ?: com.opencapture.opencine.vocabulary.ApertureStrategy.label(strategy) ?: "--"

    /**
     * Emulated angles use only the selected common shutter and reported recording cadence. The
     * operator's angle holds while the camera makes it through the nearest legal speed and while a
     * format or shutter change is [settling] ([GamepadShutterSync.angleLabel]). Swift twin.
     */
    public fun shutterAngle(common: ShutterValue?, frameRate: Rational?, available: List<Int>, preferredAngle: Double,
        settling: Boolean = false): String {
        if (common == null) return "--"
        val held = speed(common, frameRate) ?: return if (settling && common != ShutterValue.Auto)
            ShutterAngle.label(ShutterAngle.nearestDegrees(preferredAngle))
        else MonitorCapturePresentation.label(SettingValue.Shutter(common))
        return GamepadShutterSync.angleLabel(held.first, held.second, available, preferredAngle, settling)
    }

    /** The speed the camera really makes while it holds the operator's angle; null when exact, settling or not held. */
    public fun shutterAngleAchieved(common: ShutterValue?, frameRate: Rational?, available: List<Int>, preferredAngle: Double,
        settling: Boolean = false): String? {
        if (settling || common == null) return null
        val (denom, fps) = speed(common, frameRate) ?: return null
        if (ShutterAngle.denom(preferredAngle, fps, available) != denom) return null
        return ShutterAngle.achieved(preferredAngle, denom, fps)
    }

    /** The 1/N and whole rate behind a common shutter: a duration, or the emulated angle at the reported cadence. */
    private fun speed(common: ShutterValue, frameRate: Rational?): Pair<Int, Int>? {
        if (frameRate == null || frameRate.doubleValue !in 8.0..240.0) return null
        val seconds = when (common) {
            is ShutterValue.Duration -> common.seconds.doubleValue
            is ShutterValue.Angle -> if (common.degrees.isFinite() && common.degrees > 0 && common.degrees <= 360)
                common.degrees / (360 * frameRate.doubleValue) else return null
            else -> return null
        }
        if (seconds <= 0.0 || seconds > 1.0) return null
        val reciprocal = 1.0 / seconds
        if (!reciprocal.isFinite() || reciprocal >= Int.MAX_VALUE.toDouble()) return null
        return reciprocal.roundToInt() to frameRate.doubleValue.roundToInt()
    }

    /** A native focus strategy does not replace an observed Single or Manual base mode. */
    public fun focus(common: FocusMode?, native: FocusOption?): String {
        if (native in listOf(FocusOption.PRODUCT_SHOWCASE, FocusOption.SUBJECT_LOCK, FocusOption.REGISTERED_PRIORITY) &&
            (common == null || common == FocusMode.CONTINUOUS)) {
            return requireNotNull(native).chip
        }
        return common?.let { MonitorCapturePresentation.label(SettingValue.FocusMode(it)) } ?: "--"
    }
}
