package com.opencapture.opencine.relayruntime

import com.opencapture.opencine.relay.RelayControlWireCodec
import com.opencapture.opencine.relay.RelayEncoderProfile
import com.opencapture.opencine.relay.RelayHostControl
import com.opencapture.opencine.relay.RelayJoinPolicy
import com.opencapture.opencine.relay.RelayPeerHello
import com.opencapture.opencine.relay.RelaySocketPolicy
import com.opencapture.opencine.relay.RelayStreamBuffer
import com.opencapture.opencine.relay.RelayStreamFraming
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select

/** Actual listener and peer ownership. Byte queues, passive refusal, authorization before parked
 * identity restoration, exact command admission and deadline cancellation are shared behavior. */
public class RelaySocketHost<State, Metadata, Command, Control, Denied>(
    private val scope: CoroutineScope,
    private val codec: RelayControlWireCodec<State, Metadata, Command, Control, Denied>,
    private val hostName: String,
    private val cameraName: String?,
    private val sockets: RelaySocketFactory = JdkRelaySocketFactory(),
    private val policy: RelaySocketPolicy = RelaySocketPolicy(),
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    public var onPeerCountChanged: ((Int) -> Unit)? = null
    public var onControlChanged: ((String?, String?) -> Unit)? = null
    public var onCommand: ((Command, RelayHostControl.Admission) -> Unit)? = null
    public var onFailure: ((String) -> Unit)? = null
    public val pendingRequest: RelayHostControl.PendingRequest?
        get() = synchronized(lock) { if (active) control.pendingRequest else null }
    private val lock: Any = Any()
    private val control: RelayHostControl = RelayHostControl(policy.parkedLeaseMillis)
    private var window: UUID = UUID.randomUUID()
    private var active: Boolean = false
    private val peers: MutableMap<UUID, Peer> = linkedMapOf()
    private var listener: RelaySocketListener? = null
    private var acceptJob: Job? = null
    private var expiryJob: Job? = null
    private var latestState: ByteArray? = null
    public var boundPort: Int = 0
        private set
    public var watcherPasscode: String = ""
    public var allowsControlRequests: Boolean = true
    public var encoderProfile: RelayEncoderProfile = RelayEncoderProfile.LOW_LATENCY
    private data class Packet(val bytes: ByteArray, val source: UUID?, val courtesy: Boolean = false)
    private inner class Peer(val socket: RelayDuplex, depth: Int) {
        val id: UUID = UUID.randomUUID()
        var hello: RelayPeerHello? = null
        var authorized: Boolean = false
        var closing: Boolean = false
        val commands: Channel<Packet> = Channel(policy.maximumControlQueue)
        val states: Channel<Packet> = Channel(1, onBufferOverflow = BufferOverflow.DROP_OLDEST)
        // Preserve the deployed pending-frame depths; current socket write is outside this lane.
        val frames: Channel<Packet> = Channel(depth, onBufferOverflow = BufferOverflow.DROP_OLDEST)
        var writer: Job? = null
        var reader: Job? = null
    }

    public fun start(preferredPort: Int = 0): Boolean {
        val started = synchronized(lock) {
            if (active) return true
            val service = try { sockets.listen(preferredPort) } catch (error: Exception) {
                onFailure?.invoke("Couldn't start sharing: ${error.message}")
                return false
            }
            listener = service
            window = UUID.randomUUID()
            active = true
            boundPort = service.port
            service to window
        }
        val service = started.first
        val token = started.second
        acceptJob = scope.launch {
            try {
                while (synchronized(lock) { admits(token) && listener === service }) {
                    val socket = service.accept()
                    val peer = synchronized(lock) {
                        if (!admits(token) || listener !== service) null else {
                            Peer(socket, encoderProfile.maxInFlightFramesPerPeer).also {
                                peers[it.id] = it
                                control.register(it.id, "A device", authorized = false)
                            }
                        }
                    }
                    if (peer == null) socket.close() else attach(peer, token)
                }
            } catch (_: Exception) { /* Listener/source retirement closes this accept. */ }
        }
        return true
    }

    private fun attach(peer: Peer, token: UUID): Unit {
        peer.commands.trySend(Packet(RelayStreamFraming.encode(0x01, codec.encodeHello(
            RelayPeerHello(codec.profile.version, hostName, cameraName))), source = null))
        peer.writer = scope.launch {
            try {
                while (true) {
                    val packet = select<Packet?> {
                        peer.commands.onReceiveCatching { it.getOrNull() }
                        peer.states.onReceiveCatching { it.getOrNull() }
                        peer.frames.onReceiveCatching { it.getOrNull() }
                    } ?: break
                    val allowed = synchronized(lock) {
                        (admits(token) && peers[peer.id] === peer && !peer.closing &&
                            (packet.source == null || packet.source == control.source)) ||
                            (packet.courtesy && peer.closing)
                    }
                    if (allowed) peer.socket.write(packet.bytes)
                }
            } catch (_: Exception) { drop(peer, token) }
        }
        peer.reader = scope.launch {
            val stream = RelayStreamBuffer(codec.profile)
            try {
                while (synchronized(lock) { admits(token) && peers[peer.id] === peer }) {
                    val bytes = peer.socket.receive(64 * 1024) ?: break
                    for (message in stream.append(bytes)) handle(peer, token, message)
                }
            } catch (_: Exception) { /* Malformed/oversized/closed transport retires this peer. */ }
            finally { drop(peer, token) }
        }
        notifyState(token)
    }

    private fun handle(peer: Peer, token: UUID, message: RelayStreamFraming.Decoded): Unit {
        synchronized(lock) {
            if (!admits(token) || peers[peer.id] !== peer || peer.closing) return
            when (message.kind) {
                0x01 -> {
                    val hello = codec.decodeHello(message.payload)
                    val refusal = RelayJoinPolicy.refusal(
                        hello, codec.profile, watcherPasscode, policy.versionMismatchReason,
                        if (hello.passcode == null) policy.missingPasscodeReason else policy.wrongPasscodeReason,
                        requiresVersionMatch = policy.requiresHostVersionMatch)
                    peer.hello = hello
                    peer.authorized = refusal == null
                    // A refused identity never claims the prior holder's parked lease.
                    val resumed = control.introduce(peer.id, hello, peer.authorized, nowMillis())
                    if (refusal != null) {
                        peer.commands.trySend(Packet(RelayStreamFraming.encode(0x05,
                            codec.encodeDenied(refusal.reason, refusal.passcodeRequired)), null))
                    } else {
                        latestState?.let { peer.states.trySend(Packet(it, control.source)) }
                        if (resumed) { expiryJob?.cancel(); expiryJob = null; sendControlLocked() }
                    }
                }
                0x10 -> { if (control.request(peer.id, allowsControlRequests)) notifyControlLocked() }
                0x11 -> {
                    if (control.holder == peer.id) { control.reclaim(); sendControlLocked() }
                }
                0x12 -> {
                    val admission = control.admission(peer.id) ?: return
                    val command = codec.decodeCommand(message.payload)
                    // Consumers receive the exact captured admission and recheck it at camera dispatch.
                    onCommand?.invoke(command, admission)
                }
            }
            notifyControlLocked()
        }
    }
    public fun admits(admission: RelayHostControl.Admission): Boolean = synchronized(lock) {
        active && control.admits(admission)
    }
    public fun retireSource(): Unit = synchronized(lock) {
        control.resetSource()
        latestState = null
        expiryJob?.cancel()
        expiryJob = null
        for (peer in peers.values) {
            control.register(peer.id, peer.hello?.hostName ?: "A device", peer.authorized)
            peer.hello?.let { control.introduce(peer.id, it, peer.authorized, nowMillis()) }
        }
        sendControlLocked()
        notifyControlLocked()
    }
    public suspend fun broadcastState(state: State): Unit = synchronized(lock) {
        if (!active) return
        val packet = RelayStreamFraming.encode(0x02, codec.encodeState(state))
        latestState = packet
        peers.values.filter { it.authorized && !it.closing }.forEach {
            it.states.trySend(Packet(packet, control.source))
        }
    }
    public suspend fun broadcastFrame(metadata: Metadata, image: ByteArray): Unit = synchronized(lock) {
        if (!active) return
        val packet = Packet(RelayStreamFraming.encode(0x03, codec.encodeFrame(metadata, image)), control.source)
        peers.values.filter { it.authorized && !it.closing }.forEach { it.frames.trySend(packet) }
    }
    public suspend fun grantPendingControl(): Unit = synchronized(lock) {
        if (active && control.grantPending()) { expiryJob?.cancel(); expiryJob = null; sendControlLocked(); notifyControlLocked() }
    }
    public suspend fun declinePendingControl(): Unit = synchronized(lock) { control.declinePending(); notifyControlLocked() }
    public suspend fun grantPendingControl(request: RelayHostControl.PendingRequest): Unit = synchronized(lock) {
        if (active && control.grantPending(request)) {
            expiryJob?.cancel(); expiryJob = null; sendControlLocked(); notifyControlLocked()
        }
    }
    public suspend fun declinePendingControl(request: RelayHostControl.PendingRequest): Unit = synchronized(lock) {
        if (active && control.declinePending(request)) notifyControlLocked()
    }
    public suspend fun reclaimControl(): Unit = synchronized(lock) {
        control.reclaim(); expiryJob?.cancel(); expiryJob = null; sendControlLocked(); notifyControlLocked()
    }

    private fun drop(peer: Peer, token: UUID): Unit {
        synchronized(lock) {
            if (!admits(token) || peers[peer.id] !== peer) { peer.socket.close(); return }
            peers.remove(peer.id)
            peer.commands.close()
            peer.states.close()
            peer.frames.close()
            peer.socket.close()
            peer.writer?.cancel()
            val expiry = control.drop(peer.id, nowMillis())
            if (expiry != null) {
                expiryJob?.cancel()
                expiryJob = scope.launch {
                    delay(policy.parkedLeaseMillis)
                    synchronized(lock) {
                        if (admits(token) && control.expire(expiry, nowMillis())) {
                            sendControlLocked(); notifyControlLocked()
                        }
                    }
                }
            }
            sendControlLocked()
            notifyControlLocked()
        }
        notifyState(token)
    }
    public suspend fun stop(notifyingViewers: String? = null): Unit {
        val stopWindow: UUID
        val retiring = synchronized(lock) {
            active = false
            window = UUID.randomUUID()
            stopWindow = window
            acceptJob?.cancel()
            listener?.close()
            listener = null
            boundPort = 0
            control.resetSource()
            expiryJob?.cancel()
            expiryJob = null
            latestState = null
            peers.values.toList().also { all ->
                peers.clear()
                all.forEach { peer ->
                    peer.closing = true
                    if (notifyingViewers != null) {
                        peer.commands.trySend(Packet(RelayStreamFraming.encode(0x05,
                            codec.encodeDenied(notifyingViewers, false)), null, courtesy = true))
                    }
                }
            }
        }
        if (notifyingViewers != null && retiring.isNotEmpty()) delay(policy.courtesyCloseMillis)
        retiring.forEach {
            it.socket.close(); it.reader?.cancel(); it.writer?.cancel(); it.commands.close(); it.states.close(); it.frames.close()
        }
        synchronized(lock) {
            if (window == stopWindow && !active) {
                onPeerCountChanged?.invoke(0)
                onControlChanged?.invoke(null, null)
            }
        }
    }
    private fun admits(token: UUID): Boolean = active && window == token
    private fun sendControlLocked(): Unit {
        peers.values.filter { it.authorized && !it.closing }.forEach {
            it.commands.trySend(Packet(RelayStreamFraming.encode(0x04,
                codec.encodeControl(control.holderName ?: hostName, control.holder == it.id)), control.source))
        }
    }
    private fun notifyControlLocked(): Unit { onControlChanged?.invoke(control.pendingName, control.holderName) }
    private fun notifyState(token: UUID): Unit {
        val count = synchronized(lock) { if (admits(token)) peers.size else return }
        onPeerCountChanged?.invoke(count)
    }
}
