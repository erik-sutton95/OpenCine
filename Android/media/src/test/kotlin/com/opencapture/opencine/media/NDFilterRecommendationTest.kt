package com.opencapture.opencine.media

import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The apps' ND labels: [MonitorNDFilterRecommendation] with an em dash for "none". */
class NDFilterRecommendationTest {
    private val none = "\u2014"

    /** A null field is not asserted for that case. */
    private data class SuggestionCase(
        val why: String,
        val pictureStops: Double,
        val ndStops: Int,
        val ndLabel: String,
        val stopsLabel: String? = null,
        val needsGlass: Boolean? = null,
        val opticalFactor: Int? = null,
    )

    @Test
    fun suggestionRoundsHotStopsOntoTheOpticalLadder() {
        val cases = listOf(
            SuggestionCase("middle gray needs no glass", 0.0, 0, none, "0.0", needsGlass = false),
            SuggestionCase("two stops hot is ND4", 2.0, 2, "ND4", "+2.0", needsGlass = true, opticalFactor = 4),
            SuggestionCase("five stops hot is ND32", 5.0, 5, "ND32", "+5.0"),
            SuggestionCase("2.3 rounds to ND4", 2.3, 2, "ND4", "+2.3"),
            SuggestionCase("half stop rounds up to ND2", 0.5, 1, "ND2"),
            SuggestionCase("under exposure does not suggest ND", -1.5, 0, none, "−1.5", needsGlass = false),
            SuggestionCase("ten stop cap is ND1000 not ND1024", 12.0, 10, "ND1000", opticalFactor = 1_000),
        )
        for (case in cases) {
            val rec = assertNotNull(MonitorNDFilterRecommendation.suggestion(case.pictureStops, none))
            assertEquals(case.ndStops, rec.ndStops, case.why)
            assertEquals(case.ndLabel, rec.ndLabel, case.why)
            case.stopsLabel?.let { assertEquals(it, rec.stopsLabel, case.why) }
            case.needsGlass?.let { assertEquals(it, rec.needsGlass, case.why) }
            case.opticalFactor?.let { assertEquals(it, rec.opticalFactor, case.why) }
        }
    }

    @Test
    fun histogramMedianMapsToPictureStops() {
        val gray = (MonitorTransfer.DLOG.middleGrayEncoded * 255).roundToInt()
        val bins = IntArray(256)
        bins[gray] = 1_000
        val rec = assertNotNull(MonitorNDFilterRecommendation.reading(bins, MonitorTransfer.DLOG, none))
        assertTrue(abs(rec.pictureStops) < 0.15)
        assertEquals(0, rec.ndStops)
    }

    @Test
    fun emptyHistogramIsNotAMeter() {
        assertNull(MonitorNDFilterRecommendation.reading(IntArray(256), MonitorTransfer.DLOG2, none))
        assertNull(MonitorNDFilterRecommendation.reading(IntArray(0), MonitorTransfer.REC709, none))
    }

    @Test
    fun labelsFollowTheOpticalLadder() {
        assertEquals(none, MonitorNDFilterRecommendation.ndLabel(0, none))
        assertEquals("ND2", MonitorNDFilterRecommendation.ndLabel(1, none))
        assertEquals("ND8", MonitorNDFilterRecommendation.ndLabel(3, none))
        assertEquals("ND32", MonitorNDFilterRecommendation.ndLabel(5, none))
        assertEquals("ND1000", MonitorNDFilterRecommendation.ndLabel(10, none))
        assertEquals("0.0", MonitorNDFilterRecommendation.stopsLabel(0.0, none))
        assertEquals("+2.3", MonitorNDFilterRecommendation.stopsLabel(2.3, none))
        assertEquals("−1.0", MonitorNDFilterRecommendation.stopsLabel(-1.0, none))
    }

    @Test
    fun densityIsThreeTenthsPerStop() {
        assertEquals("ND 0.0", MonitorNDFilterRecommendation.densityLabel(0.0, none))
        assertEquals("ND 0.3", MonitorNDFilterRecommendation.densityLabel(1.0, none))
        assertEquals("ND 0.4", MonitorNDFilterRecommendation.densityLabel(4.0 / 3.0, none))
        assertEquals("ND 1.5", MonitorNDFilterRecommendation.densityLabel(5.0, none))
        assertEquals("ND −0.3", MonitorNDFilterRecommendation.densityLabel(-1.0, none))
    }

    @Test
    fun chipLabelFollowsNotation() {
        val hot = assertNotNull(MonitorNDFilterRecommendation.suggestion(5.0, none))
        assertEquals("+5.0", hot.chipLabel(MonitorNDFilterNotation.STOPS))
        assertEquals("ND32", hot.chipLabel(MonitorNDFilterNotation.FACTOR))
        assertEquals("ND 1.5", hot.chipLabel(MonitorNDFilterNotation.DENSITY))
        val tiffen = assertNotNull(MonitorNDFilterRecommendation.suggestion(4.0 / 3.0, none))
        assertEquals("ND 0.4", tiffen.chipLabel(MonitorNDFilterNotation.DENSITY))
        assertEquals("ND2", tiffen.chipLabel(MonitorNDFilterNotation.FACTOR))
        val under = assertNotNull(MonitorNDFilterRecommendation.suggestion(-1.5, none))
        assertEquals(none, under.chipLabel(MonitorNDFilterNotation.FACTOR))
        assertEquals("−1.5", under.chipLabel(MonitorNDFilterNotation.STOPS))
        assertEquals("Stops", MonitorNDFilterNotation.STOPS.editorLabel)
        assertEquals("ND32", MonitorNDFilterNotation.FACTOR.editorLabel)
        assertEquals("ND 0.3", MonitorNDFilterNotation.DENSITY.editorLabel)
        assertEquals(MonitorNDFilterNotation.FACTOR, MonitorNDFilterNotation.fromPersisted("factor"))
        assertEquals(MonitorNDFilterNotation.DENSITY, MonitorNDFilterNotation.fromEditorLabel("ND 0.3"))
    }
}
