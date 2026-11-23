package com.opencapture.opencine.streaming

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream

/**
 * SIMULATED: a small stand-in for the Swift run controller behind [StreamingNativeApi], for JVM
 * tests of the Android shell. It behaves like `StreamRun` in outline (connect, live on connect,
 * media written only while live, reconnect a second after a loss, polite stop) and records every
 * call. It proves nothing about the real engine; the Swift tests and the hardware pass do that.
 */
class FakeStreamingNative(
    var host: String = "live.example.com",
    var port: Int = 443,
    var tls: Boolean = true,
) : StreamingNativeApi {
    /** Every call, by member name, in order. */
    val calls = mutableListOf<String>()
    var phase: StreamPhase = StreamPhase.Connecting
    var videoBitrateBps = 3_000_000
    private var wakeAtNs: Long? = null
    private var liveSinceNs: Long? = null
    private var attempts = 0
    var presetsJson: String = DEFAULT_PRESETS
    /** When set, the next `connected` answers with this refusal instead of going live. */
    var refuseWith: String? = null
    /** When set, `create` answers with this wire error name. */
    var createError: String? = null

    override fun create(
        presetId: String,
        enteredServerUrl: String,
        streamKey: String,
        formatJson: String,
        nowNs: Long,
    ): String {
        calls += "create"
        createError?.let { return """{"error":"$it"}""" }
        return """{"owner":"owner-1","tls":$tls}"""
    }

    override fun start(owner: String): ByteArray = reply("start", listOf(StreamAction.Connect(host, port)))

    override fun connected(owner: String, nowNs: Long): ByteArray {
        refuseWith?.let { reason ->
            refuseWith = null
            phase = StreamPhase.Ended(StreamEnd.Refused(reason))
            return reply("connected", listOf(StreamAction.Disconnect))
        }
        phase = StreamPhase.Live
        attempts = 0
        if (liveSinceNs == null) liveSinceNs = nowNs
        return reply("connected", listOf(StreamAction.Write(HELLO), StreamAction.RequestKeyframe))
    }

    override fun received(owner: String, bytes: ByteArray, nowNs: Long): ByteArray = reply("received", emptyList())

    override fun connectionLost(owner: String, nowNs: Long): ByteArray {
        if (phase is StreamPhase.Ended) return reply("connectionLost", emptyList())
        attempts += 1
        phase = StreamPhase.Reconnecting(attempts)
        val due = nowNs + 1_000_000_000
        wakeAtNs = due
        return reply("connectionLost", listOf(StreamAction.Disconnect, StreamAction.Wake(due)))
    }

    override fun wrote(owner: String, count: Int, nowNs: Long): ByteArray = reply("wrote", emptyList())

    override fun tick(owner: String, nowNs: Long): ByteArray {
        val due = wakeAtNs
        if (phase is StreamPhase.Reconnecting && due != null && nowNs >= due) {
            wakeAtNs = null
            return reply("tick", listOf(StreamAction.Connect(host, port)))
        }
        return reply("tick", emptyList())
    }

    override fun stop(owner: String, nowNs: Long): ByteArray {
        if (phase is StreamPhase.Ended) return reply("stop", emptyList())
        val wasLive = phase == StreamPhase.Live
        phase = StreamPhase.Ended(StreamEnd.Stopped)
        val goodbye = if (wasLive) listOf(StreamAction.Write(GOODBYE)) else emptyList()
        return reply("stop", goodbye + StreamAction.Disconnect)
    }

    override fun publishVideoConfig(owner: String, sps: ByteArray, pps: ByteArray, nowNs: Long) =
        media("publishVideoConfig", sps + pps)

    override fun publishVideo(
        owner: String,
        annexB: ByteArray,
        isKeyframe: Boolean,
        decodeMs: Int,
        presentMs: Int,
        nowNs: Long,
    ) = media("publishVideo", annexB)

    override fun publishAudioConfig(owner: String, audioSpecificConfig: ByteArray, nowNs: Long) =
        media("publishAudioConfig", audioSpecificConfig)

    override fun publishAudio(owner: String, raw: ByteArray, presentMs: Int, nowNs: Long) =
        media("publishAudio", raw)

    override fun close(owner: String) {
        calls += "close"
    }

    override fun presets(): String = presetsJson

    override fun format(
        presetId: String,
        width: Int,
        height: Int,
        fpsNum: Int,
        fpsDen: Int,
        connected: IntArray,
    ): String? = formatFor(presetId, width, height, fpsNum, fpsDen, connected, "cameraFeed")

    /** The last quality choice asked for; the upscaled one answers [FORMAT_1080P], every other [FORMAT_720P]. */
    var lastChoice: String? = null

    override fun formatFor(
        presetId: String,
        width: Int,
        height: Int,
        fpsNum: Int,
        fpsDen: Int,
        connected: IntArray,
        choice: String,
    ): String? {
        lastChoice = choice
        return when {
            presetId == "unknown" -> null
            choice == "upscaled1080p" -> FORMAT_1080P
            else -> FORMAT_720P
        }
    }

    /** Presets other than `custom` and `instagram` have a fixed `rtmps://` server; `custom` takes `rtmp://`. */
    override fun checkDestination(presetId: String, enteredServerUrl: String, streamKey: String): String = when {
        streamKey.isBlank() -> """{"error":"emptyKey"}"""
        presetId != "custom" && presetId != "instagram" -> """{"ok":true,"tls":true}"""
        enteredServerUrl.startsWith("rtmps://") -> """{"ok":true,"tls":true}"""
        presetId == "custom" && enteredServerUrl.startsWith("rtmp://") -> """{"ok":true,"tls":false}"""
        enteredServerUrl.contains("://") -> """{"error":"notRTMPS"}"""
        else -> """{"error":"invalidServerURL"}"""
    }

    override fun canStream(route: String): Boolean = route != "cameraWiFi"

    private fun media(name: String, payload: ByteArray): ByteArray =
        reply(name, if (phase == StreamPhase.Live) listOf(StreamAction.Write(payload)) else emptyList())

    private fun reply(name: String, actions: List<StreamAction>): ByteArray {
        calls += name
        val health = if (phase == StreamPhase.Live) StreamHealth.GOOD else StreamHealth.OFFLINE
        return encodeReply(actions, StreamStatus(phase, liveSinceNs, 0, videoBitrateBps, 0, 0, health))
    }

    companion object {
        val HELLO = byteArrayOf(3, 1, 2)
        val GOODBYE = byteArrayOf(9, 9)
        const val FORMAT_720P =
            """{"width":1280,"height":720,"fpsNum":30,"fpsDen":1,"videoBitrateBps":3000000,""" +
                """"keyframeIntervalSeconds":2,"audioBitrateBps":160000,"audioSampleRate":48000,"audioChannels":2}"""
        const val FORMAT_1080P =
            """{"width":1920,"height":1080,"fpsNum":30,"fpsDen":1,"videoBitrateBps":6000000,""" +
                """"keyframeIntervalSeconds":2,"audioBitrateBps":160000,"audioSampleRate":48000,"audioChannels":2}"""
        const val DEFAULT_PRESETS =
            """[{"id":"twitch","displayName":"Twitch","serverURL":"rtmps://ingest.example/app",""" +
                """"requiresServerEntry":false,"maxVideoBitrateBps":6000000,"portrait":false,"keyHint":"Copy the key."},""" +
                """{"id":"instagram","displayName":"Instagram","serverURL":null,"requiresServerEntry":true,""" +
                """"maxVideoBitrateBps":6000000,"portrait":true,"keyHint":"Copy both."},""" +
                """{"id":"custom","displayName":"Custom server","serverURL":null,"requiresServerEntry":true,""" +
                """"maxVideoBitrateBps":null,"portrait":false,"keyHint":"Paste both.","allowsPlainRTMP":true}]"""

        /** The binary reply `StreamRunWire` documents, built in Kotlin for tests. */
        fun encodeReply(actions: List<StreamAction>, status: StreamStatus): ByteArray {
            val bytes = ByteArrayOutputStream()
            val out = DataOutputStream(bytes)
            fun string(text: String) {
                val utf8 = text.toByteArray(Charsets.UTF_8)
                out.writeShort(utf8.size)
                out.write(utf8)
            }
            for (action in actions) {
                when (action) {
                    is StreamAction.Connect -> { out.writeByte(1); out.writeShort(action.port); string(action.host) }
                    is StreamAction.Write -> { out.writeByte(2); out.writeInt(action.bytes.size); out.write(action.bytes) }
                    StreamAction.Disconnect -> out.writeByte(3)
                    is StreamAction.SetVideoBitrate -> { out.writeByte(4); out.writeInt(action.bps) }
                    StreamAction.RequestKeyframe -> out.writeByte(5)
                    is StreamAction.Wake -> { out.writeByte(6); out.writeLong(action.atNs) }
                }
            }
            out.writeByte(127)
            val phase = status.phase
            out.writeByte(
                when (phase) {
                    StreamPhase.Connecting -> 0
                    StreamPhase.Live -> 1
                    is StreamPhase.Reconnecting -> 2
                    is StreamPhase.Ended -> 3
                },
            )
            out.writeInt((phase as? StreamPhase.Reconnecting)?.attempt ?: 0)
            val end = (phase as? StreamPhase.Ended)?.end
            out.writeByte(
                when (end) {
                    null -> 0
                    StreamEnd.Stopped -> 1
                    is StreamEnd.Refused -> 2
                    StreamEnd.GaveUp -> 3
                },
            )
            string((end as? StreamEnd.Refused)?.reason ?: "")
            out.writeLong(status.liveSinceNs ?: -1)
            out.writeInt(status.sentBitrateBps)
            out.writeInt(status.videoBitrateBps)
            out.writeInt(status.droppedVideoGroups)
            out.writeInt(status.droppedAudioPackets)
            out.writeByte(status.health.ordinal)
            return bytes.toByteArray()
        }
    }
}
