package com.opencapture.opencine.streaming

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class StreamEncodedMediaTest {
    private val sps = byteArrayOf(0x67, 0x64, 0x00, 0x1F, 0xAC.toByte())
    private val pps = byteArrayOf(0x68, 0xEE.toByte(), 0x3C, 0x80.toByte())

    @Test
    fun codecConfigSplitsIntoSpsAndPps() {
        val config = byteArrayOf(0, 0, 0, 1) + sps + byteArrayOf(0, 0, 0, 1) + pps
        val (s, p) = StreamEncodedMedia.splitParameterSets(config)!!
        assertContentEquals(sps, s)
        assertContentEquals(pps, p)
    }

    @Test
    fun threeByteStartCodesSplitToo() {
        val config = byteArrayOf(0, 0, 1) + sps + byteArrayOf(0, 0, 1) + pps + byteArrayOf(0)
        val (s, p) = StreamEncodedMedia.splitParameterSets(config)!!
        assertContentEquals(sps, s)
        assertContentEquals(pps, p)
    }

    @Test
    fun configWithoutPpsIsRejected() {
        assertNull(StreamEncodedMedia.splitParameterSets(byteArrayOf(0, 0, 0, 1) + sps))
        assertNull(StreamEncodedMedia.splitParameterSets(byteArrayOf()))
    }

    @Test
    fun idrIsAKeyframe() {
        assertTrue(StreamEncodedMedia.hasIdr(byteArrayOf(0, 0, 0, 1, 0x09, 0x10, 0, 0, 0, 1, 0x65, 1)))
        assertFalse(StreamEncodedMedia.hasIdr(byteArrayOf(0, 0, 0, 1, 0x41, 1)))
    }

    @Test
    fun aacFramesAdvanceBy1024Samples() {
        val timeline = AacTimeline(48_000)
        assertEquals(listOf(0, 21, 42, 64, 85), (0 until 5).map { timeline.ms(it.toLong() * 1024) })
        assertEquals(1000, timeline.ms(48_000))
    }

    @Test
    fun ptsIsMillisecondsSinceStart() {
        assertEquals(0, StreamEncodedMedia.ms(presentationUs = 5_000_000, startUs = 5_000_000))
        assertEquals(33, StreamEncodedMedia.ms(presentationUs = 5_033_400, startUs = 5_000_000))
        assertEquals(0, StreamEncodedMedia.ms(presentationUs = 4_000_000, startUs = 5_000_000))
    }
}
