package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals

class MonitorAssistValueContractTest {
    @Test fun existingPreferenceIdentifiersDecodeOutsideNativeUI() {
        assertEquals(MonitorParadeMode.YRGB, MonitorParadeMode.fromPersisted("YRGB"))
        assertEquals(MonitorGuideFamily.SOCIAL, MonitorGuideFamily.fromPersisted("Social"))
        assertEquals(MonitorGuideAspect.CINEMA, MonitorGuideAspect.fromPersisted("2.39:1"))
        assertEquals("Horizontal", MonitorAudioOrientation.HORIZONTAL.label)
        assertEquals(listOf("9:16", "4:5", "1:1", "2:3", "16:9", "1.91:1"),
            MonitorGuideAspect.ratios(MonitorGuideFamily.SOCIAL).map { it.label })
        assertEquals(2.39f, MonitorGuideAspect.CINEMA.ratio)
    }

    @Test fun storedCenterSchemaRoundTripsWithoutNativeCoordinates() {
        val landscape = MonitorScopeRect(0f, 0f, 800f, 400f)
        val value = MonitorScopeStoredCenter(MonitorScopePoint(200f, 300f), landscape)
        assertEquals(.25, value.xFraction)
        assertEquals(.75, value.yFraction)
        assertEquals(MonitorScopePoint(200f, 300f), value.center(landscape))
        assertEquals(MonitorScopePoint(100f, 600f), value.center(MonitorScopeRect(0f, 0f, 400f, 800f)))
    }

    @Test fun audioReadoutKeepsTheExistingFiniteAndAbsentDisplayPolicy() {
        assertEquals(0f, MonitorAudioReadout.fraction(Double.NaN))
        assertEquals(0f, MonitorAudioReadout.fraction(-120.0))
        assertEquals(1f, MonitorAudioReadout.fraction(12.0))
        assertEquals("\u2014", MonitorAudioReadout.label(Double.POSITIVE_INFINITY))
        assertEquals("−∞", MonitorAudioReadout.label(-60.0))
        assertEquals("−12", MonitorAudioReadout.label(-12.0))
    }
}
