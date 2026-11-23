package com.opencapture.opencine.streaming

import java.io.File
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** The Kotlin half of `Fixtures/rtmp-receive-reply-vectors.tsv`; Swift encodes the same rows in `StreamReceiveWireTests`. */
class RtmpReceiveReplyTest {
    private val vectors: Map<String, ByteArray> =
        File(System.getProperty("opencine.repositoryRoot"), "Fixtures/rtmp-receive-reply-vectors.tsv").readLines()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { it.split("\t") }
            .associate { (name, hex) -> name to hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray() }

    private fun reply(name: String) = RtmpReceiveReply.decode(vectors.getValue(name))

    @Test
    fun publishCarriesTheBytesToWriteBack() {
        val reply = reply("publish")
        assertContentEquals(byteArrayOf(0xAA.toByte(), 0xBB.toByte()), reply.outbound)
        assertEquals(listOf<RtmpReceiveEvent>(RtmpReceiveEvent.Publish), reply.events)
    }

    @Test
    fun videoConfigAndFrameRead() {
        val config = assertIs<RtmpReceiveEvent.VideoConfig>(reply("videoConfigHEVC").events.single())
        assertTrue(config.hevc && config.enhanced)
        assertContentEquals(byteArrayOf(1, 2, 3), config.record)
        val frame = assertIs<RtmpReceiveEvent.VideoFrame>(reply("videoFrameAVC").events.single())
        assertTrue(!frame.hevc && frame.keyframe)
        assertEquals(0x01020304L, frame.decodeMs)
        assertEquals(-40, frame.compositionMs)
        assertContentEquals(byteArrayOf(0, 0, 0, 1, 0x65), frame.data)
    }

    @Test
    fun audioReads() {
        val (config, frame) = reply("audio").events
        assertContentEquals(byteArrayOf(0x11, 0x90.toByte()), assertIs<RtmpReceiveEvent.AudioConfig>(config).audioSpecificConfig)
        val audio = assertIs<RtmpReceiveEvent.AudioFrame>(frame)
        assertEquals(21L, audio.timestampMs)
        assertContentEquals(byteArrayOf(1, 2, 3), audio.data)
    }

    @Test
    fun endingsCloseTheConnection() {
        val reply = reply("endings")
        assertEquals(
            listOf(
                RtmpReceiveEvent.Unpublished, RtmpReceiveEvent.VideoEnd,
                RtmpReceiveEvent.Failed("unexpectedStreamKey"), RtmpReceiveEvent.Closed,
            ),
            reply.events,
        )
        assertTrue(reply.closed)
        assertTrue(reply("empty").events.isEmpty())
    }

    @Test
    fun aTruncatedReplyReadsAsClosed() {
        assertTrue(RtmpReceiveReply.decode(byteArrayOf(0, 0, 0, 9, 1)).closed)
    }
}
