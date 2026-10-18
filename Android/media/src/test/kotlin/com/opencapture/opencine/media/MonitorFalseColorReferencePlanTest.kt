package com.opencapture.opencine.media

import kotlin.math.abs
import kotlin.math.log2
import kotlin.math.pow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MonitorFalseColorReferencePlanTest {
    @Test fun rec709RulerKeepsTheGrayZoneAndEverySecondStop() {
        val plan = MonitorFalseColorReferencePlan.signal(LiveFalseColorScale.SCENE_STOPS, MonitorTransfer.REC709, 255)
        assertEquals(listOf("−6", "−4", "−2", "18%", "clip"), plan.markers.map { it.label })
        val gray = plan.segments.first { it.band.label == "18%" }
        assertEquals(8.0 / 12, gray.lowerFraction)
        assertEquals(9.0 / 12, gray.upperFraction)
        assertEquals(7, ScopeExposureCeiling.CLIP_SHELF_CODES)
        val encoded = 248.0 / 255
        val linear = ((encoded + .099) / 1.099).pow(1 / .45)
        assertTrue(abs(plan.clipStops - log2(linear / .18)) < 1e-12)
        assertEquals(2.5 / 12, plan.markers.first().fraction)
    }
    @Test fun anIreRulerUsesTheReadThroughLooksSignalAndHasNoStopMarkers() {
        val plan = MonitorFalseColorReferencePlan.signal(LiveFalseColorScale.IRE, MonitorTransfer.NLOG, 180,
            lookCurve = listOf(0.0, .6, 1.0, 1.0), readThroughLook = true)
        assertTrue(plan.markers.isEmpty())
        val gray = plan.segments.first { it.band.label == "18%MG" }
        assertEquals(.38, gray.lowerFraction)
        assertEquals(.42, gray.upperFraction)
        assertTrue(plan.segments.all { it.lowerFraction in 0.0..1.0 && it.upperFraction in 0.0..1.0 })
    }
}
