package com.opencapture.opencine.dji

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

/** The Bluetooth link a livestream is provisioned over ([MultiviewProvisioner] on a phone). */
interface DjiLivestreamLink {
    suspend fun exchange(kind: Int, extra: String?, timeoutMs: Long): DumlFrame

    /** Closes the link and returns once it is down. */
    suspend fun closeAndWait()
}

/** Why a camera did not start its own livestream; replies are hex for the log, never a secret. */
sealed class DjiCameraStreamError(message: String) : Exception(message) {
    /** A required command got no reply: the camera may need a hard restart. */
    class NoReply : DjiCameraStreamError("no reply")

    class PrepareRefused(val reply: String) : DjiCameraStreamError("livestream mode refused $reply")

    class JoinRefused(val reply: String) : DjiCameraStreamError("join refused $reply")

    class ConfigureRefused(val reply: String) : DjiCameraStreamError("configure refused $reply")

    class StartRefused(val reply: String) : DjiCameraStreamError("start refused $reply")
}

/**
 * Starts and ends a DJI camera's own RTMP livestream to this device; twin of Swift
 * `DJICameraStreamPublisher`. End any earlier livestream, livestream mode, a 1 s settle, join the
 * shared network (retried like `MulticamJoinPolicy`), configure the address (version 00 on
 * Pocket 3, the JSON form otherwise; frames built by the shared Swift `LivestreamCommands`) and
 * start. The log holds no password and only the stream key's first 4 characters.
 */
class DjiCameraStreamPublisher(
    private val link: DjiLivestreamLink,
    private val pocket3: Boolean,
    private val log: (String) -> Unit = {},
    private val sleep: suspend (Long) -> Unit = { delay(it) },
    /** Attempts, reply timeout and retry pause from core `MulticamJoinPolicy` (through JNI on a phone). */
    private val joinPolicy: StationJoin.Policy = StationJoin.Policy.fromCore(),
) {
    /** [codec] is `hevc` or `h264`. Throws [DjiCameraStreamError]; the caller ends with [end] either way. */
    suspend fun start(url: String, ssid: String, password: String, frameRate: Int, codec: String) {
        log("livestream: start ${redacted(url)} on $ssid, $frameRate fps, ${if (pocket3) "h264" else codec}")
        try {
            exchange("end (cleanup)", DjiNative.CMD_LIVESTREAM_END, null, 5_000)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            // A livestream left over from an earlier session; no reply is needed.
        }
        val prepared = required("livestream mode", DjiNative.CMD_LIVESTREAM_PREPARE, null)
        if (prepared.firstOrNull() != 0.toByte()) throw DjiCameraStreamError.PrepareRefused(hex(prepared))
        sleep(1_000)
        join(ssid, password)
        val version = if (pocket3) "0" else "1"
        val configured = required(
            "configure", DjiNative.CMD_LIVESTREAM_CONFIGURE,
            "$version\u001f$url\u001f${if (pocket3) "h264" else codec}\u001f$frameRate\u001f$BITRATE_KBPS",
        )
        if (configured.firstOrNull() != 0.toByte()) throw DjiCameraStreamError.ConfigureRefused(hex(configured))
        val started = required("start", DjiNative.CMD_LIVESTREAM_START, null)
        if (started.firstOrNull() != 0.toByte()) throw DjiCameraStreamError.StartRefused(hex(started))
    }

    /** Ends the camera's livestream (6 s at most; no reply needed) and closes the link. */
    suspend fun end() {
        try {
            exchange("end", DjiNative.CMD_LIVESTREAM_END, null, 6_000)
        } catch (error: CancellationException) {
            link.closeAndWait()
            throw error
        } catch (_: Exception) {
        }
        link.closeAndWait()
        log("livestream: link closed")
    }

    private suspend fun join(ssid: String, password: String) {
        var last: ByteArray? = null
        val attempts = joinPolicy.maximumAttempts
        for (attempt in 1..attempts) {
            // The request carries the password; only the reply is logged.
            val reply = try {
                exchange("join attempt $attempt", DjiNative.CMD_MULTICAM_JOIN, "$ssid\u001f$password", joinPolicy.replyTimeoutMs)
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                null
            } ?: continue
            last = reply
            when {
                reply.contentEquals(byteArrayOf(0, 0)) || reply.contentEquals(byteArrayOf(0, 0, 0)) -> return
                reply.contentEquals(byteArrayOf(1, 0xFF.toByte())) && attempt < attempts -> sleep(joinPolicy.retryDelayMs)
                else -> throw DjiCameraStreamError.JoinRefused(hex(reply))
            }
        }
        throw last?.let { DjiCameraStreamError.JoinRefused(hex(it)) } ?: DjiCameraStreamError.NoReply()
    }

    private suspend fun required(label: String, kind: Int, extra: String?): ByteArray =
        try {
            exchange(label, kind, extra, 12_000)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            throw DjiCameraStreamError.NoReply()
        }

    private suspend fun exchange(label: String, kind: Int, extra: String?, timeoutMs: Long): ByteArray {
        try {
            val reply = link.exchange(kind, extra, timeoutMs).payload
            log("livestream: $label reply ${hex(reply)}")
            return reply
        } catch (error: Exception) {
            log("livestream: $label no reply")
            throw error
        }
    }

    companion object {
        /** About 6 Mbps: the camera's own 1080p encode. */
        const val BITRATE_KBPS = 6000

        private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }

        /** The address with its stream key cut to the first 4 characters. */
        fun redacted(url: String): String {
            val slash = url.lastIndexOf('/')
            return if (slash < 0) url else url.substring(0, slash + 1) + url.substring(slash + 1).take(4) + "****"
        }
    }
}

/** [MultiviewProvisioner] as the livestream link (connected and paired by the caller). */
class MultiviewLivestreamLink(private val provisioner: MultiviewProvisioner) : DjiLivestreamLink {
    override suspend fun exchange(kind: Int, extra: String?, timeoutMs: Long): DumlFrame =
        provisioner.exchange(kind, extra, timeoutMs)

    override suspend fun closeAndWait() = provisioner.close()
}
