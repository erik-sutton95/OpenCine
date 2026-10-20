package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.core.FocusMode
import com.opencapture.opencine.vocabulary.ApertureStrategy
import com.opencapture.opencine.vocabulary.FocusOption
import kotlin.test.Test
import kotlin.test.assertEquals

class CaptureNativeReadoutPresentationTest {
    @Test fun emulatedAngleUsesOnlyKnownCommonShutterAndCadence() {
        fun label(shutter: com.opencapture.opencine.core.ShutterValue?, rate: com.opencapture.opencine.core.Rational?) =
            CaptureNativeReadoutPresentation.shutterAngle(shutter, rate, listOf(25, 50, 100), 180.0)
        fun duration(n: Int, d: Int = 1) = com.opencapture.opencine.core.ShutterValue.Duration(com.opencapture.opencine.core.Rational(n, d))
        fun rate(n: Int) = com.opencapture.opencine.core.Rational(n)
        assertEquals("--", label(null, rate(25)))
        assertEquals("1/50", label(duration(1, 50), null))
        assertEquals("90°", label(duration(1, 100), rate(25)))
        assertEquals("180°", label(duration(1, 50), rate(24)))
        assertEquals("2s", label(duration(2), rate(25)))
        assertEquals("144°", label(com.opencapture.opencine.core.ShutterValue.Angle(144.0), null))
        assertEquals("1/50", label(duration(1, 50), rate(0)))
        assertEquals("1/2147483647", label(duration(1, Int.MAX_VALUE), rate(25)))
    }

    private val luna = listOf(8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640,
        500, 400, 320, 250, 200, 160, 125, 100, 80, 60, 50, 40, 30, 25, 15, 10, 5)
    private fun angle(d: Double) = com.opencapture.opencine.core.ShutterValue.Angle(d)
    private fun duration(n: Int, d: Int = 1) = com.opencapture.opencine.core.ShutterValue.Duration(com.opencapture.opencine.core.Rational(n, d))
    private fun rate(n: Int) = com.opencapture.opencine.core.Rational(n)

    /** Owner 2026-10-20: Angle 180 at 4K120 read "172.8°". Swift twin. */
    @Test fun theOperatorsAngleHoldsThroughTheNearestLegalSpeed() {
        fun label(shutter: com.opencapture.opencine.core.ShutterValue, fps: Int) =
            CaptureNativeReadoutPresentation.shutterAngle(shutter, rate(fps), luna, 180.0)
        assertEquals("180°", label(angle(172.8), 120))
        assertEquals("180°", label(angle(172.8), 24))
        assertEquals("180°", label(angle(172.8), 60))
        assertEquals("180°", label(angle(180.0), 30))
        assertEquals("180°", label(angle(180.0), 25))
        assertEquals("180°", label(duration(1, 250), 120))
        assertEquals("360°", label(angle(360.0), 30))
        assertEquals("11.2°", label(duration(1, 1000), 30))
    }

    /** Owner 2026-10-20: changing the rate flashed "42°" until the camera confirmed. Swift twin. */
    @Test fun noTransientAngleWhileAFormatOrShutterChangeSettles() {
        fun label(shutter: com.opencapture.opencine.core.ShutterValue, fps: Int, settling: Boolean) =
            CaptureNativeReadoutPresentation.shutterAngle(shutter, rate(fps), luna, 180.0, settling)
        assertEquals("180°", label(duration(1, 60), 120, true))
        assertEquals("180°", label(angle(720.0), 120, true))
        assertEquals("180°", label(duration(1, 250), 30, true))
        assertEquals("180°", label(angle(43.2), 30, true))
        assertEquals("45°", label(duration(1, 250), 30, false))
        assertEquals("180°", CaptureNativeReadoutPresentation.shutterAngle(duration(1, 60), null, luna, 180.0, true))
    }

    @Test fun theAchievedSpeedIsToldOnlyWhenItIsNotExact() {
        fun achieved(shutter: com.opencapture.opencine.core.ShutterValue, fps: Int, settling: Boolean = false) =
            CaptureNativeReadoutPresentation.shutterAngleAchieved(shutter, rate(fps), luna, 180.0, settling)
        assertEquals("1/250 (172.8°)", achieved(angle(172.8), 120))
        assertEquals("1/50 (172.8°)", achieved(duration(1, 50), 24))
        assertEquals(null, achieved(angle(180.0), 30))
        assertEquals(null, achieved(angle(172.8), 120, settling = true))
        assertEquals(null, achieved(angle(360.0), 30))
    }

    @Test fun nativeFocusStrategiesDoNotReplaceTheCommonBaseMode() {
        for (native in listOf(FocusOption.PRODUCT_SHOWCASE, FocusOption.SUBJECT_LOCK, FocusOption.REGISTERED_PRIORITY)) {
            assertEquals(native.chip, CaptureNativeReadoutPresentation.focus(FocusMode.CONTINUOUS, native))
            assertEquals(native.chip, CaptureNativeReadoutPresentation.focus(null, native))
            assertEquals("AF-S", CaptureNativeReadoutPresentation.focus(FocusMode.SINGLE, native))
            assertEquals("MF", CaptureNativeReadoutPresentation.focus(FocusMode.MANUAL, native))
        }
        assertEquals("--", CaptureNativeReadoutPresentation.focus(null, null))
        assertEquals("--", CaptureNativeReadoutPresentation.focus(null, FocusOption.SINGLE))
        assertEquals("--", CaptureNativeReadoutPresentation.focus(null, FocusOption.CONTINUOUS_DEFAULT))
        assertEquals("AF-C", CaptureNativeReadoutPresentation.focus(FocusMode.CONTINUOUS, FocusOption.SINGLE))
        assertEquals("AF-S", CaptureNativeReadoutPresentation.focus(FocusMode.SINGLE, null))
    }

    /**
     * Behavior audit PIA-269: until the measured iris arrives the APERTURE tile reads the requested
     * strategy (Action 6), as the standalone apps did, never a dash.
     */
    @Test fun apertureFallsBackToTheRequestedStrategyUntilTheIrisIsMeasured() {
        assertEquals("Starburst f/4", CaptureNativeReadoutPresentation.aperture(null, ApertureStrategy.STARBURST))
        assertEquals("--", CaptureNativeReadoutPresentation.aperture(null, -1))
        assertEquals(com.opencapture.opencine.appkit.MonitorCapturePresentation.label(
            com.opencapture.opencine.core.SettingValue.Aperture(2.8)),
            CaptureNativeReadoutPresentation.aperture(2.8, ApertureStrategy.STARBURST))
    }
}
