package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MonitorAssistOptionsTest {
    @Test fun detectorPaintsRetainGoldenRGBAndSensitivity() {
        assertEquals(listOf(Triple(246.0 / 255, 241.0 / 255, 226.0 / 255),
            Triple(64.0 / 255, 142.0 / 255, 1.0), Triple(1.0, 72.0 / 255, 64.0 / 255),
            Triple(74.0 / 255, 220.0 / 255, 132.0 / 255)), MonitorPeakingColor.entries.map { it.rgb })
        assertEquals(listOf(2.30, 2.10, 1.90), MonitorPeakingSense.entries.map { it.ratioThreshold })
        assertEquals(listOf(0.00522, 0.00174, 0.00058), MonitorPeakingSense.entries.map { it.noiseGate })
        assertEquals(MonitorPeakingOverlaySpec(MonitorPeakingColor.RED, MonitorPeakingSense.MED),
            MonitorPeakingOptions.Default.overlay)
    }

    @Test fun serializedOptionIdentitiesRemainCompatible() {
        assertEquals(MonitorPeakingColor.BLUE, MonitorPeakingColor.fromPersisted("Blue"))
        assertEquals(MonitorPeakingColor.BLUE, MonitorPeakingColor.fromPersisted("BLUE"))
        assertEquals(MonitorPeakingSense.HIGH, MonitorPeakingSense.fromPersisted("High"))
        assertEquals(MonitorPeakingSense.MED, MonitorPeakingSense.fromPersisted("MED"))
        assertEquals(listOf("White", "Amber", "Red", "Cyan", "Green"), MonitorZebraPaint.entries.map { it.label })
        assertEquals(listOf(Triple(1.0, 1.0, 1.0), Triple(1.0, 0.72, 0.2),
            Triple(1.0, 0.15, 0.15), Triple(0.0, 0.85, 0.9), Triple(0.2, 0.9, 0.35)),
            MonitorZebraPaint.entries.map { it.rgb })
    }

    @Test fun histogramAndLightsRetainCompensationStopsAndLenientDecode() {
        assertEquals(listOf(0, 2, 5, 7, 10), MonitorCrushClipCompensation.entries.map { it.raw })
        assertEquals(listOf(0.0, 0.25, 0.5, 0.75, 1.0), MonitorCrushClipCompensation.entries.map { it.stops })
        assertEquals(listOf("0", "¼", "½", "¾", "1"), MonitorCrushClipCompensation.entries.map { it.compactLabel })
        for ((raw, expected) in listOf(-1 to 0, 3 to 0, 15 to 10, 2 to 2, 5 to 5)) {
            assertEquals(expected, MonitorCrushClipCompensation.fromRaw(raw).raw)
        }
        assertEquals(0.05, MonitorCrushClipCompensation.HALF.pixelFractionThreshold)
    }

    @Test fun desqueezePresetsAndHundredthsRetainTheirIdentities() {
        assertEquals(listOf(1.1, 1.2, 1.33, 1.5, 1.6, 1.8, 2.0), MonitorDesqueezePreset.entries.map { it.factor })
        for (hundredths in 100..200) {
            val value = hundredths / 100.0
            assertEquals(value, MonitorAnamorphicDesqueeze.snap(value))
        }
        assertNull(MonitorDesqueezePreset.matching(1.32))
        assertNull(MonitorDesqueezePreset.matching(1.34))
        assertEquals(1.01, MonitorAnamorphicDesqueeze.snap(1.005))
        assertEquals(1.34, MonitorAnamorphicDesqueeze.snap(1.335))
        assertEquals(1.33, MonitorAnamorphicDesqueeze.snap(Double.NaN))
        assertEquals("1.34×", MonitorAnamorphicDesqueeze.label(1.337))
    }

    @Test fun desqueezeNeverManufacturesUnknownSourceGeometry() {
        for (value in listOf(null, 0f, -1f, Float.POSITIVE_INFINITY, Float.NaN)) {
            assertNull(MonitorAnamorphicDesqueeze.aspect(value, true, 2.0, MonitorDesqueezeDirection.HORIZONTAL))
        }
        assertEquals(4f, MonitorAnamorphicDesqueeze.aspect(2f, true, 2.0, MonitorDesqueezeDirection.HORIZONTAL))
        assertEquals(1f, MonitorAnamorphicDesqueeze.aspect(2f, true, 2.0, MonitorDesqueezeDirection.VERTICAL))
        assertEquals(2f, MonitorAnamorphicDesqueeze.aspect(2f, false, 2.0, MonitorDesqueezeDirection.HORIZONTAL))
    }
}
