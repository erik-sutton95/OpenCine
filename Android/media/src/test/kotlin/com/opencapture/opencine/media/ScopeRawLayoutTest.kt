package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ScopeRawLayoutTest {
    @Test fun explicitLayoutsPreserveEncodedChannelsAndExactLuma() {
        val rgba = byteArrayOf(-1, 0, 0, -1, 0, -1, 0, -1, 0, 0, -1, -1)
        val bgra = byteArrayOf(0, 0, -1, -1, 0, -1, 0, -1, -1, 0, 0, -1)
        val first = ScopeSampler.sampleRaw(rgba, 3, 1, 12, MonitorTransfer.REC709, true,
            MonitorScopeByteLayout.RGBA, stride = 1)
        val second = ScopeSampler.sampleRaw(bgra, 3, 1, 12, MonitorTransfer.REC709, true,
            MonitorScopeByteLayout.BGRA, stride = 1)
        assertEquals(first.points, second.points)
        assertEquals(listOf(54, 182, 18), first.points.map { it.luma })
        assertEquals(listOf(255, 0, 0), first.points.map { it.red })
        assertTrue(first.points.all { it.sampleX == null && it.sampleY == null })
    }
    @Test fun paddedRowsAndRequestedStridePreserveExactKnownCoordinates() {
        val bytes = ByteArray(48)
        for (y in 0..<3) for (x in 0..<3) bytes[y * 16 + x * 4] = (y * 10 + x).toByte()
        val samples = ScopeSampler.sampleRaw(bytes, 3, 3, 16, MonitorTransfer.REC709, true,
            MonitorScopeByteLayout.RGBA, stride = 2, includeSampleCoordinates = true,
            requireCompleteRows = true)
        assertEquals(listOf(0, 2, 20, 22), samples.points.map { it.red })
        assertEquals(listOf(0, 2, 0, 2), samples.points.map { it.sampleX })
        assertEquals(listOf(0, 0, 2, 2), samples.points.map { it.sampleY })
        assertEquals(4, samples.histogramRed.sum())
    }
    @Test fun incompleteRowsRefuseOnlyUnderExplicitSourcePolicy() {
        val bytes = byteArrayOf(-1, 0, 0, -1, -1, -1)
        val compatibility = ScopeSampler.sampleRaw(bytes, 2, 2, 8, MonitorTransfer.REC709, true)
        val refused = ScopeSampler.sampleRaw(bytes, 2, 2, 8, MonitorTransfer.REC709, true,
            requireCompleteRows = true)
        assertEquals(1, compatibility.points.size)
        assertEquals(emptyList(), refused.points)
        assertEquals(0, refused.histogramRed.sum())
    }
    @Test fun originalAndroidDefaultRetainsRGBAAndNoInventedCoordinates() {
        val samples = ScopeSampler.sampleRaw(byteArrayOf(10, 20, 30, -1), 1, 1, 4,
            MonitorTransfer.REC709, true)
        assertEquals(10, samples.points.first().red)
        assertEquals(30, samples.points.first().blue)
        assertEquals(null, samples.points.first().sampleX)
        assertEquals(null, samples.points.first().sampleY)
    }
}
