package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.appkit.MonitorCapturePresentation
import com.opencapture.opencine.core.FocusMode
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.vocabulary.GamepadShutterSync
import kotlin.math.roundToInt
import com.opencapture.opencine.vocabulary.FocusOption

/** Common reports and coherent native strategy values remain distinct. */
public object CaptureNativeReadoutPresentation {
    /** Emulated angles use only the selected common shutter and reported recording cadence. */
    public fun shutterAngle(common: ShutterValue?, frameRate: Rational?, available: List<Int>, preferredAngle: Double): String {
        if (common == null) return "--"
        val fallback = MonitorCapturePresentation.label(SettingValue.Shutter(common))
        if (common !is ShutterValue.Duration || frameRate == null ||
            frameRate.doubleValue !in 8.0..240.0 || common.seconds.doubleValue <= 0.0 || common.seconds.doubleValue > 1.0) return fallback
        val reciprocal = 1.0 / common.seconds.doubleValue
        if (!reciprocal.isFinite() || reciprocal >= Int.MAX_VALUE.toDouble()) return fallback
        return GamepadShutterSync.angleLabel(reciprocal.roundToInt(), frameRate.doubleValue.roundToInt(), available, preferredAngle)
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
