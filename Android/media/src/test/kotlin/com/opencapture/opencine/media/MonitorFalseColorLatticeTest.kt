package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.math.pow

class MonitorFalseColorLatticeTest {
    @Test fun packedGridKeepsRedFastestFloatCoordinatesAndRounding() {
        val cube = MonitorLUTCube.fromRGB(2, floatArrayOf(
            -1f, 0f, 1f, 0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f, 0.7f, 0.8f, 0.9f,
            1.1f, 0.25f, 0.75f, 0.125f, 0.375f, 0.625f, 0.875f, 0.0625f, 0.1875f, 0.3125f, 0.4375f, 0.5625f,
        ))
        assertEquals(listOf(
            0, 0, 255, 255, 26, 51, 77, 255, 255, 64, 191, 255, 32, 96, 159, 255,
            102, 128, 153, 255, 179, 204, 230, 255, 223, 16, 48, 255, 80, 112, 143, 255,
        ), cube.rgba.map { it.toInt() and 255 })
    }

    @Test fun limitsKeepSeparatePaintWeightAndSourceGaps() {
        val painting = MonitorFalseColorPainting(
            listOf(LiveFalseColorBand(0.0, 10.0, 0.4, 0.2, 0.8, "shadow")), 0.5,
            MonitorFalseColorReadingDomain.MONITOR_PERCENT, MonitorFalseColorBackground.SOURCE)
        assertEquals(MonitorFalseColorPaint(0.0, 0.0, 0.0, 0.0), painting.paint(50.0, 0.5))
        assertEquals(Triple(0.2, 0.4, 0.6), painting.compositeColor(50.0, 0.5, Triple(0.2, 0.4, 0.6)))
        assertEquals(MonitorFalseColorPaint(0.4, 0.2, 0.8, 0.5), painting.paint(10.0, 0.5))
    }

    @Test fun managedPaintDecodesBeforeFloatConversionAndNeverDecodesMasks() {
        val lattice = MonitorFalseColorLattice.signal(LiveFalseColorScale.IRE, MonitorTransfer.REC709, 255, size = 2)
        val v = 115.0 / 255
        val expected = ((v + 0.055) / 1.055).pow(2.4).toFloat()
        assertEquals(expected.toBits(), lattice.rgb(MonitorFalseColorCubeComponent.PAINT,
            MonitorFalseColorPaintEncoding.LINEAR_SRGB)[0].toBits())
        assertTrue(lattice.rgb(MonitorFalseColorCubeComponent.WEIGHT,
            MonitorFalseColorPaintEncoding.LINEAR_SRGB).all { it == 1f })
    }

    @Test fun sceneLinearUsesSuppliedDecodedChannelsAndDetailBlend() {
        val painting = MonitorFalseColorPainting(listOf(LiveFalseColorBand(Double.NEGATIVE_INFINITY,
            Double.POSITIVE_INFINITY, 0.4, 0.2, 0.8, "declared")), 0.05,
            MonitorFalseColorReadingDomain.SCENE_STOPS, MonitorFalseColorBackground.MONITOR_GRAY, 0.4)
        val tone = MonitorSceneToneMap(1.0)
        val rgb = MonitorFalseColorLattice.sceneLinear(listOf(0.0, 1.0), Triple(0.2126, 0.7152, 0.0722),
            tone, painting).rgb(MonitorFalseColorCubeComponent.COMPOSITE)
        val gray = tone.displayCode(0.2126)
        assertEquals((0.4 * 0.6 + gray * 0.4).toFloat().toBits(), rgb[3].toBits())
        assertEquals((0.2 * 0.6 + gray * 0.4).toFloat().toBits(), rgb[4].toBits())
        assertEquals((0.8 * 0.6 + gray * 0.4).toFloat().toBits(), rgb[5].toBits())
    }

    @Test fun unknownOfficialLookNeverInventsReadThrough() {
        assertFalse(LiveColorScience.readsThroughLook(null, true))
        assertEquals(MonitorFalseColorReading(0.5, MonitorTransfer.ILOG),
            LiveColorScience.falseColorReading(0.5, MonitorTransfer.ILOG, true, null))
        assertEquals(MonitorFalseColorClip(MonitorTransfer.DLOG2, 247 / 255.0),
            LiveColorScience.falseColorClip(LiveFalseColorScale.SCENE_STOPS,
                MonitorTransfer.DLOG2, true, null, 247 / 255.0))
    }

    @Test fun memoizedBytesAndSuppliedCurveAreIndependentSnapshots() {
        val curve = mutableListOf(0.0, 0.4, 0.8, 1.0)
        val lattice = MonitorFalseColorLattice.signal(LiveFalseColorScale.IRE, MonitorTransfer.DLOG2,
            247, lookCurve = curve, readThroughLook = true, size = 2)
        val expected = lattice.packedCube().rgba.copyOf()
        curve[0] = 1.0
        val callerBytes = lattice.packedCube().rgba
        callerBytes[0] = 0
        assertContentEquals(expected, lattice.packedCube().rgba)
        val changed = MonitorFalseColorLattice.signal(LiveFalseColorScale.IRE, MonitorTransfer.DLOG2,
            247, lookCurve = curve, readThroughLook = true, size = 2)
        assertFalse(expected.contentEquals(changed.packedCube().rgba))
    }
}
