package com.opencapture.opencine.streaming

import kotlin.test.Test
import kotlin.test.assertEquals

/** Same scenarios as Swift `StreamFramePacerTests`. */
class StreamFramePacerTest {
    private val ms = 1_000_000L

    @Test
    fun slowSourceRepeatsFrames() {
        val pacer = StreamFramePacer()
        pacer.submit(0)
        assertEquals(List(4) { StreamFramePacer.Frame.PICTURE }, listOf(0L, 33, 66, 100).map { pacer.frame(it * ms) })
    }

    @Test
    fun fastSourceSkipsToTheNewest() {
        val pacer = StreamFramePacer()
        pacer.submit(0)
        pacer.submit(10 * ms)
        pacer.submit(20 * ms)
        assertEquals(StreamFramePacer.Frame.PICTURE, pacer.frame(2_015 * ms))
    }

    @Test
    fun lostSourceShowsSlateAfterTwoSeconds() {
        val pacer = StreamFramePacer()
        pacer.submit(0)
        assertEquals(StreamFramePacer.Frame.PICTURE, pacer.frame(1_999 * ms))
        assertEquals(StreamFramePacer.Frame.SLATE, pacer.frame(2_000 * ms))
        pacer.submit(2_100 * ms)
        assertEquals(StreamFramePacer.Frame.PICTURE, pacer.frame(2_100 * ms))
    }

    @Test
    fun noPictureYetIsSlate() {
        assertEquals(StreamFramePacer.Frame.SLATE, StreamFramePacer().frame(0))
    }
}
