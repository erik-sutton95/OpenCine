package com.opencapture.opencine.dji

import android.content.Context
import android.net.Network
import com.opencapture.opencine.platform.SharedWiFiPath
import com.opencapture.opencine.vocabulary.FoundCamera
import java.net.InetSocketAddress
import java.net.Socket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.withContext
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import org.json.JSONObject

/**
 * The operator's shared IPv4 path as a DJI datalink path: the generic [SharedWiFiPath] with the
 * Multiview diagnostics.
 */
class SharedWiFi(context: Context) : SharedWiFiPath(
    context, log = { level, code, message -> DjiLog.log(level, "multiview", code, "multiview: $message") },
), CameraNetworkPath {
    companion object {
        fun mask(prefix: Int): String = SharedWiFiPath.mask(prefix)

        /** iOS `SharedWiFiPath.validAddress`: unicast IPv4, not loopback. */
        fun validAddress(value: String): Boolean = SharedWiFiPath.validAddress(value)
    }
}

/** Service candidates only. The session verifies the BLE identity before preview. */
class MultiviewDiscovery(private val path: SharedWiFi) {
    @Volatile private var cancelled = false
    fun cancel() { cancelled = true }

    suspend fun candidates(excluding: Set<String>): List<String> {
        val address = path.address() ?: throw UnsupportedSubnet()
        val mask = path.netmask() ?: throw UnsupportedSubnet()
        val request = JSONObject().put("address", address).put("mask", mask)
            .put("excluding", excluding.joinToString(",")).toString()
        val reply = DjiNative.multicamDecision("discoveryHosts", request)
        if (reply == null || reply == "unsupported") throw UnsupportedSubnet()
        val hosts = reply.split(",").filter { it.isNotEmpty() }
        val found = mutableListOf<String>()
        for (batch in hosts.chunked(BATCH)) {
            currentCoroutineContext().ensureActive()
            if (cancelled) throw kotlinx.coroutines.CancellationException("discovery cancelled")
            found += coroutineScope {
                batch.map { host -> async(Dispatchers.IO) { if (probe(host, address)) host else null } }.awaitAll()
            }.filterNotNull()
            if (found.size >= MAX_CANDIDATES) break
        }
        return found.take(MAX_CANDIDATES)
    }

    private fun probe(host: String, local: String): Boolean {
        if (cancelled) return false
        return runCatching {
            Socket().use { socket ->
                path.bindSocket(socket)
                if (path.hotspot) socket.bind(InetSocketAddress(local, 0))
                socket.connect(InetSocketAddress(host, 7001), PROBE_MS)
                true
            }
        }.getOrDefault(false)
    }

    class UnsupportedSubnet :
        Exception("Automatic discovery needs a shared IPv4 network with at most 1,022 device addresses.")

    private companion object {
        const val BATCH = 24
        const val MAX_CANDIDATES = 8
        const val PROBE_MS = 800
    }
}

/** One camera owns one BLE link, sequence space, reply router and keepalive. iOS `MultiviewProvisioner`. */
class MultiviewProvisioner(context: Context) {
    private val ble = BleLink(context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val replies = HashMap<Int, DumlFrame>()
    private var router: Job? = null
    private var keepalive: Job? = null
    private var sequence = 1200
    private var approved = false
    @Volatile private var closed = false

    /** Reported Wi-Fi networks from a `07/AC` scan result. */
    var onWiFiScan: ((List<String>) -> Unit)? = null

    fun next(): Int {
        sequence = (sequence + 1) and 0xFFFF
        return sequence
    }

    fun send(kind: Int, extra: String? = null): Int {
        val seq = next()
        if (!closed) ble.send(DjiNative.command(kind, seq, extra))
        return seq
    }

    suspend fun exchange(kind: Int, extra: String? = null, timeoutMs: Long = 12_000): DumlFrame {
        if (closed) throw kotlinx.coroutines.CancellationException("provisioner closed")
        val seq = next()
        val bytes = DjiNative.command(kind, seq, extra)
        require(bytes.size > 10) { "command not encoded" }
        val cmdSet = bytes[9].toInt() and 0xFF
        val cmdId = bytes[10].toInt() and 0xFF
        replies.remove(seq)
        ble.send(bytes)
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (closed) throw kotlinx.coroutines.CancellationException("provisioner closed")
            val reply = replies.remove(seq)
            if (reply != null && reply.cmdSet == cmdSet && reply.cmdId == cmdId) return reply
            delay(50)
        }
        android.util.Log.i(
            "Multiview",
            "multiview: BLE ${"%02x".format(cmdSet)}/${"%02x".format(cmdId)} seq=$seq reply timeout",
        )
        throw MultiviewFailure.Timeout()
    }

    suspend fun connect(camera: FoundCamera, pairingTimeoutMs: Long = 90_000) {
        val powerDeadline = System.currentTimeMillis() + 8_000
        while (!ble.radioOn.value && System.currentTimeMillis() < powerDeadline) {
            if (closed) throw kotlinx.coroutines.CancellationException("provisioner closed")
            delay(100)
        }
        if (!ble.radioOn.value) throw MultiviewFailure.Unavailable()
        if (closed) throw kotlinx.coroutines.CancellationException("provisioner closed")
        try {
            ble.connect(camera)
        } catch (error: kotlinx.coroutines.CancellationException) {
            throw error
        } catch (error: Exception) {
            android.util.Log.i("Multiview", "multiview: BLE connect failed ${error.javaClass.simpleName}: ${error.message}")
            throw MultiviewFailure.Unavailable()
        }
        if (closed) throw kotlinx.coroutines.CancellationException("provisioner closed")
        router = scope.launch {
            ble.frames.collect { frame ->
                if (closed) return@collect
                android.util.Log.d(
                    "Multiview",
                    "ble frame ${"%02x".format(frame.cmdSet)}/${"%02x".format(frame.cmdId)} " +
                        "seq=${frame.seq} flags=${"%02x".format(frame.flags)} bytes=${frame.payload.size}",
                )
                if (frame.cmdSet == 0x07 && frame.cmdId == 0xAC && frame.sender == 0x07) {
                    val names = DjiNative.multicamDecision(
                        "wifiScanNames", JSONObject().put("payload", hex(frame.payload)).toString())
                    onWiFiScan?.invoke(names.orEmpty().split('\u001f').filter { it.isNotEmpty() })
                }
                if (frame.cmdSet == 0x07 && frame.cmdId == 0x46 && (frame.flags and 0x80) == 0) {
                    ble.send(DjiNative.command(DjiNative.CMD_PAIR_APPROVAL_ACK, frame.seq))
                    approved = true
                } else if ((frame.flags and 0x80) != 0) {
                    if (replies.size > 128) replies.clear()
                    replies[frame.seq] = frame
                }
            }
        }
        send(DjiNative.CMD_SESSION_WAKE)
        val pair = send(DjiNative.CMD_SET_PAIRING_PIN, camera.model.pairingToken)
        val deadline = System.currentTimeMillis() + pairingTimeoutMs
        while (!approved && System.currentTimeMillis() < deadline) {
            if (closed) throw kotlinx.coroutines.CancellationException("provisioner closed")
            replies.remove(pair)?.let { response ->
                approved = acceptsMultiviewPairingReply(response, pair)
            }
            if (!approved) delay(100)
        }
        if (!approved) throw MultiviewFailure.Timeout()
        keepalive = scope.launch {
            while (!closed) {
                send(DjiNative.CMD_SESSION_KEEPALIVE)
                delay(1_000)
            }
        }
    }

    /** Same bounded camera scan as iOS Add setup, including AP return on this BLE link. */
    suspend fun scanNetworks(
        camera: FoundCamera,
        beforeStationChange: () -> Unit,
        onRestored: (Boolean) -> Unit,
        onFound: (String) -> Unit,
    ) {
        val seen = mutableSetOf<String>()
        onWiFiScan = { names -> names.filter { seen.add(it) }.forEach(onFound) }
        var restoreNeeded = false
        try {
            connect(camera, pairingTimeoutMs = 30_000)
            if (camera.model.family == "nano") exchange(DjiNative.CMD_SESSION_5310)
            beforeStationChange()
            restoreNeeded = true
            val role = exchange(DjiNative.CMD_MULTICAM_STATION_MODE, "1")
            if (role.payload.firstOrNull()?.toInt() != 0) throw MultiviewFailure.Rejected()
            delay(10_000)
            repeat(4) {
                try {
                    exchange(DjiNative.CMD_MULTICAM_WIFI_SCAN, timeoutMs = 8_000)
                } catch (error: CancellationException) {
                    throw error
                } catch (_: MultiviewFailure.Timeout) {
                    // Reports can still arrive after a lost scan acknowledgement.
                }
                delay(5_000)
            }
        } finally {
            withContext(NonCancellable) {
                val restored = restoreNeeded && runCatching {
                    val reply = exchange(DjiNative.CMD_MULTICAM_STATION_MODE, "0").payload
                    reply.contentEquals(byteArrayOf(0)) || reply.contentEquals(byteArrayOf(0, 0))
                }.getOrDefault(false)
                close()
                if (restoreNeeded) onRestored(restored)
            }
        }
    }

    fun close() {
        if (closed) return
        closed = true
        keepalive?.cancel()
        router?.cancel()
        scope.cancel()
        replies.clear()
        // BleLink owns a HandlerThread and a radio receiver; close() also disconnects.
        ble.close()
    }
}

/** iOS `MultiviewSession.Failure`. */
sealed class MultiviewFailure(message: String) : Exception(message) {
    class Timeout : MultiviewFailure("Camera did not respond. Close other camera apps and try again.")
    class Unavailable : MultiviewFailure("Camera is not nearby. Check that it is powered on.")
    class PairingDeferred : MultiviewFailure("Camera is not ready to pair again. Please try again.")
    class Rejected : MultiviewFailure("Camera could not complete this step. Check the Wi-Fi details and try again.")
    class Network : MultiviewFailure("Join the shared Wi-Fi network on this device first.")
    class Message(text: String) : MultiviewFailure(text)
}

/** Exact pairing replies; a deferred session is never treated as approval. */
internal fun acceptsMultiviewPairingReply(response: DumlFrame, sequence: Int): Boolean {
    if (response.seq != sequence || response.cmdSet != 7 || response.cmdId != 0x45 ||
        response.flags and 0x80 == 0) return false
    return when (response.payload.map { it.toInt() and 0xff }) {
        listOf(0, 1) -> true
        listOf(0, 2) -> false
        listOf(0, 6) -> throw MultiviewFailure.PairingDeferred()
        else -> throw MultiviewFailure.Rejected()
    }
}

/** One Exit handles the captured post-session 00 06 reply, at most three attempts. */
suspend fun restoreCameraWiFiWithRetry(
    waitBetween: suspend () -> Unit = { delay(3_000) },
    attempt: suspend () -> Boolean,
): Boolean {
    repeat(3) { index ->
        try {
            return attempt()
        } catch (error: CancellationException) {
            throw error
        } catch (_: MultiviewFailure.PairingDeferred) {
            if (index == 2) return false
            waitBetween()
        } catch (_: Exception) {
            return false
        }
    }
    return false
}
