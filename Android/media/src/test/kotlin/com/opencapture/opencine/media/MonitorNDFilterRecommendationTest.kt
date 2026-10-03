package com.opencapture.opencine.media

import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MonitorNDFilterRecommendationTest {
    @Test fun suggestionFollowsTheOpticalLadder() {
        for ((stops, ndStops, label) in listOf(Triple(0.0, 0, "?"), Triple(0.3, 0, "?"),
            Triple(0.5, 1, "ND2"), Triple(2.0, 2, "ND4"), Triple(2.3, 2, "ND4"), Triple(3.0, 3, "ND8"),
            Triple(5.0, 5, "ND32"), Triple(12.0, 10, "ND1000"), Triple(-1.0, 0, "?"), Triple(-1.5, 0, "?"))) {
            val reading = assertNotNull(MonitorNDFilterRecommendation.suggestion(stops))
            assertEquals(ndStops, reading.ndStops)
            assertEquals(label, reading.ndLabel)
            assertEquals(ndStops > 0, reading.needsGlass)
        }
    }

    @Test fun histogramMedianMapsToPictureStops() {
        val bins = IntArray(256)
        bins[(MonitorTransfer.REC709.middleGrayEncoded * 255).roundToInt()] = 1_000
        val reading = assertNotNull(MonitorNDFilterRecommendation.reading(bins, MonitorTransfer.REC709))
        assertTrue(abs(reading.pictureStops) < 0.15)
        assertEquals(0, reading.ndStops)
    }

    @Test fun unavailableMeasurementIsNotKnownZero() {
        for (input in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            assertNull(MonitorNDFilterRecommendation.suggestion(input))
        }
        assertNull(MonitorNDFilterRecommendation.reading(IntArray(0), MonitorTransfer.REC709))
        assertNull(MonitorNDFilterRecommendation.reading(IntArray(256), MonitorTransfer.REC709))
        val zero = assertNotNull(MonitorNDFilterRecommendation.suggestion(0.0, "No ND"))
        assertEquals(0.0, zero.pictureStops)
        assertEquals("No ND", zero.ndLabel)
        assertFalse(zero.needsGlass)
    }

    @Test fun largestFiniteMeasurementCapsBeforeIntegerConversion() {
        val reading = assertNotNull(MonitorNDFilterRecommendation.suggestion(Double.MAX_VALUE))
        assertEquals(10, reading.ndStops)
        assertEquals(1_000, reading.opticalFactor)
    }

    @Test fun densityAndNotationPreserveMeasuredValues() {
        for ((stops, label) in listOf(0.0 to "ND 0.0", 1.0 to "ND 0.3", (4.0 / 3.0) to "ND 0.4",
            5.0 to "ND 1.5", -1.0 to "ND −0.3")) {
            assertEquals(label, MonitorNDFilterRecommendation.densityLabel(stops))
        }
        val hot = assertNotNull(MonitorNDFilterRecommendation.suggestion(5.0))
        assertEquals("+5.0", hot.chipLabel(MonitorNDFilterNotation.STOPS))
        assertEquals("ND32", hot.chipLabel(MonitorNDFilterNotation.FACTOR))
        assertEquals("ND 1.5", hot.chipLabel(MonitorNDFilterNotation.DENSITY))
        assertEquals(listOf("stops", "factor", "density"), MonitorNDFilterNotation.entries.map { it.persisted })
        assertEquals(listOf("Stops", "ND32", "ND 0.3"), MonitorNDFilterNotation.entries.map { it.editorLabel })
    }
}
