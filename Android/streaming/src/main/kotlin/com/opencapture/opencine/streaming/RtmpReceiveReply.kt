package com.opencapture.opencine.streaming

import java.nio.BufferUnderflowException
import java.nio.ByteBuffer

/** What the shared receive session reports for a camera publishing to this device. */
sealed interface RtmpReceiveEvent {
    /** The publisher published under the expected key. */
    data object Publish : RtmpReceiveEvent

    class VideoConfig(val hevc: Boolean, val enhanced: Boolean, val record: ByteArray) : RtmpReceiveEvent {
        override fun toString(): String = "VideoConfig(hevc=$hevc, enhanced=$enhanced, ${record.size} bytes)"
    }

    /** Length-prefixed NAL units, decode time and composition offset in milliseconds. */
    class VideoFrame(
        val hevc: Boolean,
        val keyframe: Boolean,
        val decodeMs: Long,
        val compositionMs: Int,
        val data: ByteArray,
    ) : RtmpReceiveEvent {
        override fun toString(): String = "VideoFrame(hevc=$hevc, key=$keyframe, dts=$decodeMs, cts=$compositionMs)"
    }

    class AudioConfig(val audioSpecificConfig: ByteArray) : RtmpReceiveEvent

    class AudioFrame(val timestampMs: Long, val data: ByteArray) : RtmpReceiveEvent

    data object Unpublished : RtmpReceiveEvent

    /** The session failed; [reason] is a case name, never the key. */
    data class Failed(val reason: String) : RtmpReceiveEvent

    data object VideoEnd : RtmpReceiveEvent

    /** The session is over: close the connection. */
    data object Closed : RtmpReceiveEvent
}

/** One `StreamingNative.receiverFeed` reply: bytes to write back, then events in order. */
class RtmpReceiveReply(val outbound: ByteArray, val events: List<RtmpReceiveEvent>) {
    val closed: Boolean get() = events.any { it == RtmpReceiveEvent.Closed }

    companion object {
        /** Reads the reply Swift `StreamReceiveWire` documents; a malformed reply reads as closed. */
        fun decode(bytes: ByteArray): RtmpReceiveReply =
            try {
                read(ByteBuffer.wrap(bytes))
            } catch (_: BufferUnderflowException) {
                RtmpReceiveReply(ByteArray(0), listOf(RtmpReceiveEvent.Closed))
            } catch (_: IllegalArgumentException) {
                RtmpReceiveReply(ByteArray(0), listOf(RtmpReceiveEvent.Closed))
            }

        private fun ByteBuffer.bytes(count: Int): ByteArray {
            require(count in 0..remaining())
            return ByteArray(count).also { get(it) }
        }

        private fun read(buffer: ByteBuffer): RtmpReceiveReply {
            val outbound = buffer.bytes(buffer.int)
            val count = buffer.short.toInt() and 0xFFFF
            val events = ArrayList<RtmpReceiveEvent>(count)
            repeat(count) {
                val kind = buffer.get().toInt() and 0xFF
                val body = ByteBuffer.wrap(buffer.bytes(buffer.int))
                when (kind) {
                    1 -> events += RtmpReceiveEvent.Publish
                    2 -> {
                        val hevc = body.get().toInt() == 1
                        val enhanced = body.get().toInt() == 1
                        events += RtmpReceiveEvent.VideoConfig(hevc, enhanced, body.bytes(body.remaining()))
                    }
                    3 -> {
                        val hevc = body.get().toInt() == 1
                        val key = body.get().toInt() == 1
                        val dts = body.int.toLong() and 0xFFFF_FFFFL
                        val cts = body.int
                        events += RtmpReceiveEvent.VideoFrame(hevc, key, dts, cts, body.bytes(body.remaining()))
                    }
                    4 -> events += RtmpReceiveEvent.AudioConfig(body.bytes(body.remaining()))
                    5 -> {
                        val ts = body.int.toLong() and 0xFFFF_FFFFL
                        events += RtmpReceiveEvent.AudioFrame(ts, body.bytes(body.remaining()))
                    }
                    6 -> events += RtmpReceiveEvent.Unpublished
                    7 -> events += RtmpReceiveEvent.Failed(String(body.bytes(body.remaining()), Charsets.UTF_8))
                    9 -> events += RtmpReceiveEvent.VideoEnd
                    10 -> events += RtmpReceiveEvent.Closed
                }
            }
            return RtmpReceiveReply(outbound, events)
        }
    }
}
