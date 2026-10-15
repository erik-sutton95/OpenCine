package com.opencapture.opencine.media

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LegacyScopePolicyTest {
    private val calibration = LegacyScopeCalibration(20.0, 80.0, 200.0, 200.0, 24.0)
    private fun histogram(vararg entries: Pair<Int, Int>) = IntArray(256).apply {
        for ((bin, count) in entries) this[bin] = count
    }
    private fun point(code: Int) = ScopePoint(0.0, 0.0, code, code, code, code)

    @Test fun fixedAnchorsUseDefaultClipForGray() {
        val shifted = LegacyScopeCalibration(20.0, 80.0, 180.0, 200.0, 24.0)
        assertTrue(abs(LegacyScopePolicy.middleGrayLevel(calibration) - .35) < 1e-12)
        assertEquals(LegacyScopePolicy.middleGrayLevel(calibration), LegacyScopePolicy.middleGrayLevel(shifted))
        assertEquals(.05, LegacyScopePolicy.waveformLevel(20.0, shifted))
        assertEquals(.95, LegacyScopePolicy.waveformLevel(180.0, shifted))
        assertEquals(1.0, LegacyScopePolicy.waveformLevel(255.0, shifted))
    }
    @Test fun histogramMedianKeepsLowerEvenBin() {
        assertEquals(.05, LegacyScopePolicy.medianWaveformLevel(histogram(20 to 1, 200 to 1), calibration))
    }
    @Test fun pointMedianAveragesEvenLevels() {
        assertEquals(.5, LegacyScopePolicy.medianWaveformLevel(listOf(point(200), point(20)), calibration) { it.red })
    }
    @Test fun histogramTotalsUseWideCounters() {
        val bins = histogram(20 to 1_000_000_000, 80 to 1_000_000_000, 255 to 1_000_000_000)
        assertTrue(abs(LegacyScopePolicy.medianWaveformLevel(bins, calibration) - .35) < 1e-12)
        assertTrue(LegacyScopePolicy.trafficLights(bins, bins, bins, calibration).clipRed)
    }
    @Test fun edgeEnergyIsStrictAndExcludesSubFloor() {
        val exactly = histogram(80 to 90, 255 to 10)
        assertFalse(LegacyScopePolicy.trafficLights(exactly, exactly, exactly, calibration, .10).clipRed)
        val belowToe = histogram(0 to 100)
        assertFalse(LegacyScopePolicy.trafficLights(belowToe, belowToe, belowToe, calibration).crushRed)
        val toe = histogram(20 to 100)
        assertTrue(LegacyScopePolicy.trafficLights(toe, toe, toe, calibration).crushRed)
    }
    @Test fun emptyHistogramInputKeepsOriginalZeros() {
        assertEquals(0.0, LegacyScopePolicy.medianWaveformLevel(intArrayOf(1, 2, 3), calibration))
        assertEquals(LegacyTrafficLightsReading.empty, LegacyTrafficLightsMeter.measure(ScopeSamples.EMPTY, MonitorCrushClipCompensation.QUARTER, calibration))
    }
    @Test fun individualChannelsClipIndependently() {
        val gray = histogram(80 to 100)
        val reading = LegacyTrafficLightsMeter.measure(ScopeSamples(gray, histogram(255 to 100), gray, gray, emptyList()),
            MonitorCrushClipCompensation.QUARTER, calibration)
        assertTrue(reading.red.clip && !reading.green.clip && !reading.blue.clip)
        assertTrue(reading.red.level == 1.0 && reading.green.level == .5)
    }
    @Test fun channelLevelUsesHistogramBeforePoints() {
        val gray = histogram(80 to 100)
        val samples = ScopeSamples(gray, gray, gray, gray, listOf(point(255)))
        assertEquals(.5, LegacyTrafficLightsMeter.channelLevel(samples, LegacyTrafficLightsChannel.RED, calibration))
    }
    @Test fun channelDisplayKeepsInclusiveDeadZone() {
        assertEquals(LegacyTrafficLightsChannelDisplay.neutral,
            LegacyTrafficLightsMeter.channelDisplay(LegacyTrafficLightsChannelReading(.625, false, false), deadZone = .125))
        val over = LegacyTrafficLightsMeter.channelDisplay(LegacyTrafficLightsChannelReading(.75, false, false))
        val under = LegacyTrafficLightsMeter.channelDisplay(LegacyTrafficLightsChannelReading(.25, false, false))
        assertTrue(over.side == LegacyTrafficLightsBarSide.OVER && over.barFill == .5)
        assertTrue(under.side == LegacyTrafficLightsBarSide.UNDER && under.barFill == .5)
    }
}
