package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame

class ScopeSamplingTest {
    private fun calibratedCeiling() = ScopeExposureCeiling(ScopeClipProfile(mapOf(
        MonitorTransfer.DLOG2 to ScopeClipCalibration(1600, 247, 248),
    ), defaultIso = 1600))

    @Test fun singlePassKeepsNativeCodesAndSourceHistory() {
        val white = ByteArray(4 * 4 * 4) { 255.toByte() }
        val first = ScopeSampler.sample(white, 4, 4, 16, MonitorTransfer.REC709, includePoints = true)
        assertEquals(4, first.samples.histogramLuma[255])
        assertEquals(4, first.samples.histogramRed[255])
        assertEquals(4, first.samples.points.size)
        val dark = ByteArray(4 * 4 * 4) { 16 }
        val owner = calibratedCeiling()
        val second = ScopeSampler.sample(dark, 4, 4, 16, MonitorTransfer.DLOG2,
            includePoints = true, previous = first, ceiling = owner)
        assertEquals(2L, second.revision)
        assertEquals(4, second.samples.histogramLuma[16])
        assertSame(first.samples, second.trailSamples)
        assertEquals(247, second.ceiling.clipByte(second.transfer))
        val independent = ScopeSampler.sample(dark, 4, 4, 16, MonitorTransfer.DLOG2,
            includePoints = false, ceiling = calibratedCeiling().apply { setISO(100) })
        assertEquals(1L, independent.revision)
        assertSame(ScopeSamples.EMPTY, independent.trailSamples)
        assertEquals(100, independent.iso)
        owner.setISO(100)
        assertEquals(247, second.ceiling.clipByte(second.transfer))
        assertEquals(100, owner.resolvedISO())
    }

    @Test fun histogramRemapConservesCounts() {
        val bins = IntArray(256)
        bins[16] = 10; bins[78] = 20; bins[247] = 30
        val remapped = WaveformIre.remapHistogram(bins, MonitorTransfer.DLOG2, ceiling = calibratedCeiling())
        assertEquals(10, remapped[0])
        assertEquals(30, remapped[255])
        assertEquals(60, remapped.sum())
    }

    @Test fun sourceOwnedLevelAxisPlacesCodesAndGreyLine() {
        val transfer = ScopeLevelAxis.of(MonitorTransfer.DLOG2, ceiling = calibratedCeiling())
        assertEquals(
            WaveformIre.levelTable(MonitorTransfer.DLOG2, ceiling = calibratedCeiling()).toList(),
            transfer.table.toList(),
        )
        assertEquals(MonitorTransfer.DLOG2.middleGrayPaperIRE, transfer.middleGrayIre)

        // A source with its own placement: code c sits at c/255 * 100 IRE, grey at 41.
        val linear = ScopeLevelAxis(FloatArray(256) { it / 255f * 100f }, 41.0)
        val bins = IntArray(256).also { it[0] = 5; it[128] = 7; it[255] = 9 }
        assertEquals(bins.toList(), linear.remapHistogram(bins).toList())
        val display =
            ScopeSampler.histogramDisplay(
                ScopeSamples(bins, bins, bins, bins, emptyList()),
                ScopeHistogramDisplay.EMPTY,
                linear,
            )
        assertEquals(
            ScopeSampler.displayChannel(bins, ScopeHistogramDisplay.EMPTY.luma, linear).toList(),
            display.luma.toList(),
        )
        assertEquals(true, display.luma[128] > 0f)
    }

    @Test fun samplingCadenceShedsScopes() {
        assertEquals(1_000_000_000L / 25, ScopeSampler.minIntervalNs(2))
        assertEquals(1_000_000_000L / 10, ScopeSampler.minIntervalNs(3))
        assertEquals(300_000_000L, ScopeSampler.minIntervalNs(3, 3.0))
    }
}
