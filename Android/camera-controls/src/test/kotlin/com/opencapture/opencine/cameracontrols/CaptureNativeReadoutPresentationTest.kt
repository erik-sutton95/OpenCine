package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.core.FocusMode
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
}
