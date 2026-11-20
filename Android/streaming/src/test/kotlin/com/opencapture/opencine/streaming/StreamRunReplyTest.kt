package com.opencapture.opencine.streaming

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertIs

class StreamRunReplyTest {
    /** The exact bytes Swift's `encodesEveryActionInOrderThenTheStatus` pins. */
    private val swiftReply = byteArrayOf(
        1, 0x01, 0xBB.toByte(), 0, 1, 0x68,
        2, 0, 0, 0, 2, 9, 8,
        3,
        4, 0, 0, 1, 2,
        5,
        6, 0, 0, 0, 0, 0x3B, 0x9A.toByte(), 0xCA.toByte(), 0x01,
        127, 2, 0, 0, 0, 2, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 5,
        0, 0, 0, 7, 0, 0x2D, 0xC6.toByte(), 0xC0.toByte(), 0, 0, 0, 1, 0, 0, 0, 2, 2,
    )

    @Test
    fun decodesEveryActionInOrder() {
        val reply = StreamRunReply.decode(swiftReply)
        assertEquals(StreamAction.Connect("h", 443), reply.actions[0])
        assertContentEquals(byteArrayOf(9, 8), assertIs<StreamAction.Write>(reply.actions[1]).bytes)
        assertEquals(
            listOf(
                StreamAction.Disconnect, StreamAction.SetVideoBitrate(258), StreamAction.RequestKeyframe,
                StreamAction.Wake(1_000_000_001),
            ),
            reply.actions.drop(2),
        )
        assertEquals(
            StreamStatus(StreamPhase.Reconnecting(2), 5, 7, 3_000_000, 1, 2, StreamHealth.OFFLINE),
            reply.status,
        )
    }

    @Test
    fun statusRoundTripsEveryPhase() {
        val phases = listOf(
            StreamPhase.Connecting, StreamPhase.Live, StreamPhase.Reconnecting(3),
            StreamPhase.Ended(StreamEnd.Stopped), StreamPhase.Ended(StreamEnd.Refused("Bad key")),
            StreamPhase.Ended(StreamEnd.GaveUp),
        )
        for (phase in phases) {
            for (health in StreamHealth.entries) {
                val status = StreamStatus(phase, null, 1, 2, 3, 4, health)
                assertEquals(status, StreamRunReply.decode(FakeStreamingNative.encodeReply(emptyList(), status)).status)
            }
        }
    }

    @Test
    fun truncatedReplyIsEnded() {
        val reply = StreamRunReply.decode(swiftReply.copyOf(swiftReply.size - 3))
        assertEquals(StreamStatus.ENDED, reply.status)
        assertEquals(listOf<StreamAction>(StreamAction.Disconnect), reply.actions)
        assertEquals(StreamStatus.ENDED, StreamRunReply.decode(byteArrayOf(2, 0x7F, 0, 0, 0)).status)
        assertEquals(StreamStatus.ENDED, StreamRunReply.decode(byteArrayOf(42)).status)
    }

    @Test
    fun writeDescriptionHoldsNoBytes() {
        assertEquals("Write(3 bytes)", StreamAction.Write("KEY".toByteArray()).toString())
    }
}
