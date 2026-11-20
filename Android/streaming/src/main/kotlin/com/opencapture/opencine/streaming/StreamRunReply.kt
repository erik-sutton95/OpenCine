package com.opencapture.opencine.streaming

import java.nio.BufferUnderflowException
import java.nio.ByteBuffer

/** One thing the run controller asks the shell to do, in reply order. */
sealed interface StreamAction {
    /** Open the connection; report `connected` or `connectionLost`. */
    data class Connect(val host: String, val port: Int) : StreamAction

    /** Write these bytes; report each completed write with `wrote`. */
    class Write(val bytes: ByteArray) : StreamAction {
        override fun toString(): String = "Write(${bytes.size} bytes)"
    }

    /** Close the connection and report nothing back. */
    data object Disconnect : StreamAction

    data class SetVideoBitrate(val bps: Int) : StreamAction

    /** Encode the next picture as a keyframe. */
    data object RequestKeyframe : StreamAction

    /** Call `tick` at this instant (nanoseconds on the caller's clock). */
    data class Wake(val atNs: Long) : StreamAction
}

/** Why a stream ended. */
sealed interface StreamEnd {
    data object Stopped : StreamEnd

    /** The server refused the stream; [reason] holds no stream key. */
    data class Refused(val reason: String) : StreamEnd

    /** The connection did not come back within the reconnect window. */
    data object GaveUp : StreamEnd
}

sealed interface StreamPhase {
    data object Connecting : StreamPhase

    data object Live : StreamPhase

    /** Waiting to reconnect or connecting again; [attempt] counts from 1. */
    data class Reconnecting(val attempt: Int) : StreamPhase

    data class Ended(val end: StreamEnd) : StreamPhase
}

enum class StreamHealth { GOOD, CONGESTED, OFFLINE }

/** What the operator sees of a stream: the twin of Swift `StreamRun.Status`. */
data class StreamStatus(
    val phase: StreamPhase,
    /** When the stream first went live, for elapsed time; null before. */
    val liveSinceNs: Long?,
    val sentBitrateBps: Int,
    val videoBitrateBps: Int,
    val droppedVideoGroups: Int,
    val droppedAudioPackets: Int,
    val health: StreamHealth,
) {
    companion object {
        val ENDED = StreamStatus(StreamPhase.Ended(StreamEnd.Stopped), null, 0, 0, 0, 0, StreamHealth.OFFLINE)
        val CONNECTING = StreamStatus(StreamPhase.Connecting, null, 0, 0, 0, 0, StreamHealth.OFFLINE)
    }
}

/** One reply of the run controller: actions to apply in order, then the status after them. */
class StreamRunReply(val actions: List<StreamAction>, val status: StreamStatus) {
    companion object {
        /**
         * Decodes the binary reply `StreamRunWire` documents. A damaged or truncated reply is
         * treated as an ended stream with its readable actions dropped: the shell then closes.
         */
        fun decode(bytes: ByteArray): StreamRunReply = try {
            decodeOrThrow(ByteBuffer.wrap(bytes))
        } catch (_: BufferUnderflowException) {
            StreamRunReply(listOf(StreamAction.Disconnect), StreamStatus.ENDED)
        } catch (_: IllegalArgumentException) {
            StreamRunReply(listOf(StreamAction.Disconnect), StreamStatus.ENDED)
        }

        private fun decodeOrThrow(buffer: ByteBuffer): StreamRunReply {
            val actions = mutableListOf<StreamAction>()
            while (true) {
                when (val tag = buffer.get().toInt() and 0xFF) {
                    1 -> {
                        val port = buffer.short.toInt() and 0xFFFF
                        actions += StreamAction.Connect(buffer.string(), port)
                    }
                    2 -> {
                        val count = buffer.int
                        require(count in 0..buffer.remaining())
                        actions += StreamAction.Write(ByteArray(count).also { buffer.get(it) })
                    }
                    3 -> actions += StreamAction.Disconnect
                    4 -> actions += StreamAction.SetVideoBitrate(buffer.int)
                    5 -> actions += StreamAction.RequestKeyframe
                    6 -> actions += StreamAction.Wake(buffer.long)
                    127 -> return StreamRunReply(actions, buffer.status())
                    else -> throw IllegalArgumentException("unknown reply tag $tag")
                }
            }
        }

        private fun ByteBuffer.string(): String {
            val count = short.toInt() and 0xFFFF
            require(count <= remaining())
            return String(ByteArray(count).also { get(it) }, Charsets.UTF_8)
        }

        private fun ByteBuffer.status(): StreamStatus {
            val phase = get().toInt() and 0xFF
            val attempt = int
            val end = get().toInt() and 0xFF
            val reason = string()
            val liveSince = long
            val sent = int
            val video = int
            val groups = int
            val audio = int
            val health = when (get().toInt() and 0xFF) {
                0 -> StreamHealth.GOOD
                1 -> StreamHealth.CONGESTED
                2 -> StreamHealth.OFFLINE
                else -> throw IllegalArgumentException("unknown health")
            }
            val decoded = when (phase) {
                0 -> StreamPhase.Connecting
                1 -> StreamPhase.Live
                2 -> StreamPhase.Reconnecting(attempt)
                3 -> StreamPhase.Ended(
                    when (end) {
                        2 -> StreamEnd.Refused(reason)
                        3 -> StreamEnd.GaveUp
                        else -> StreamEnd.Stopped
                    },
                )
                else -> throw IllegalArgumentException("unknown phase")
            }
            return StreamStatus(decoded, liveSince.takeIf { it >= 0 }, sent, video, groups, audio, health)
        }
    }
}
