package com.opencapture.opencine.media

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MonitorLogDisplayTransformTest {
    private val identity = floatArrayOf(1f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 1f)

    @Test fun anchorsGrayAndCopiesTheSourceMatrix() {
        val matrix = identity.copyOf()
        val transform = MonitorLogDisplayTransform({ it }, matrix)
        matrix[0] = 0f
        val output = transform.map(0.18f, 0.18f, 0.18f)
        assertTrue(abs(output.first - 0.42f) < 0.000001f)
        assertEquals(output.first, output.second)
        assertEquals(output.second, output.third)
    }

    @Test fun rotatesNegativeDecodedChannelsBeforeClamping() {
        val transform = MonitorLogDisplayTransform({ it - 0.25 },
            floatArrayOf(-1f, 1f, 0f, 0f, 1f, 0f, 0f, 0f, 1f))
        val output = transform.map(0f, 0.5f, 0.25f)
        val tone = MonitorSceneToneMap(0.75)
        assertEquals(tone.displayCode(0.5).toFloat(), output.first)
        assertEquals(tone.displayCode(0.25).toFloat(), output.second)
        assertEquals(0f, output.third)
    }

    @Test fun gridIsRedFastestAndRetainsLargerPublicDimensions() {
        val transform = MonitorLogDisplayTransform({ it }, identity)
        val rgb = transform.rgb(2)
        assertEquals(24, rgb.size)
        assertEquals(listOf(0f, 0f, 0f), rgb.slice(0..2))
        assertEquals(listOf(1f, 0f, 0f), rgb.slice(3..5))
        assertEquals(listOf(0f, 1f, 0f), rgb.slice(6..8))
        assertEquals(listOf(0f, 0f, 1f), rgb.slice(12..14))
        assertEquals(65 * 65 * 65 * 3, transform.rgb(65).size)
    }

    @Test fun neutralReadingInterpolatesTheCubeInsteadOfTheAnalyticTransform() {
        val transform = MonitorLogDisplayTransform({ it * it * it * it }, identity)
        val curve = transform.neutralLumaCurve(cubeSize = 2, sampleCount = 3)
        assertEquals(3, curve.size)
        assertTrue(abs(curve[1] - 0.5) < 0.000000000001)
        assertTrue(abs(transform.map(0.5f, 0.5f, 0.5f).first.toDouble() - curve[1]) > 0.01)
    }
}
