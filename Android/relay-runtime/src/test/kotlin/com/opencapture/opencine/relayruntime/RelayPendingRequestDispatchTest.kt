package com.opencapture.opencine.relayruntime

import com.opencapture.opencine.relay.RelayControlWireCodec
import com.opencapture.opencine.relay.RelayFrameBlob
import com.opencapture.opencine.relay.RelayFramePayload
import com.opencapture.opencine.relay.RelayPeerHello
import com.opencapture.opencine.relay.RelayStreamFraming
import com.opencapture.opencine.relay.RelayVideoDescription
import com.opencapture.opencine.relay.RelayWireProfile
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** SIMULATED queue waits exercise the real retained socket host and broadcast window. */
@OptIn(ExperimentalCoroutinesApi::class)
class RelayPendingRequestDispatchTest {
    private val codec = Codec()

    @Test fun queuedGrantCannotConsumeSamePeerRepeatedRequest() = runTest {
        repeatAfterWait(grant = true)
    }
    @Test fun queuedDeclineCannotConsumeSamePeerRepeatedRequest() = runTest {
        repeatAfterWait(grant = false)
    }
    private suspend fun TestScope.repeatAfterWait(grant: Boolean) {
        val sockets = Sockets()
        val host = RelaySocketHost(backgroundScope, codec, "SIMULATED producer", null, sockets)
        assertTrue(host.start())
        val peer = Socket()
        sockets.listeners.single().incoming.send(peer)
        peer.input.send(hello() + message(0x10))
        runCurrent()
        val old = assertNotNull(host.pendingRequest)
        val gate = CompletableDeferred<Unit>()
        backgroundScope.launch {
            gate.await()
            if (grant) host.grantPendingControl(old) else host.declinePendingControl(old)
        }
        runCurrent()
        host.declinePendingControl(old)
        peer.input.send(message(0x10))
        runCurrent()
        val current = assertNotNull(host.pendingRequest)
        assertEquals(old.source, current.source)
        assertEquals(old.peer, current.peer)
        assertNotEquals(old.requestRevision, current.requestRevision)
        gate.complete(Unit)
        runCurrent()
        assertEquals(current, host.pendingRequest)
        assertTrue(peer.controls().none { it })
        host.grantPendingControl(current)
        runCurrent()
        assertNull(host.pendingRequest)
        assertTrue(peer.controls().last())
        host.stop()
    }

    @Test fun queuedOwnerGrantCannotUseReplacementHost() = runTest {
        val sockets = Sockets()
        val owner = owner(sockets)
        assertTrue(owner.start(Any(), "same label", null))
        val first = Socket()
        sockets.listeners.last().incoming.send(first)
        first.input.send(hello() + message(0x10))
        runCurrent()
        val old = assertNotNull(owner.pendingRequest)
        owner.grantPendingControl(old)
        assertTrue(owner.start(Any(), "same label", null))
        val successor = Socket()
        sockets.listeners.last().incoming.send(successor)
        successor.input.send(hello() + message(0x10))
        runCurrent()
        val current = assertNotNull(owner.pendingRequest)
        assertNotEquals(old.source, current.source)
        assertNull(owner.status.value.controlHolderName)
        owner.grantPendingControl(old)
        owner.declinePendingControl(old)
        runCurrent()
        assertEquals(current, owner.pendingRequest)
        assertTrue(successor.controls().none { it })
        owner.grantPendingControl(current)
        runCurrent()
        assertNull(owner.pendingRequest)
        assertTrue(successor.controls().last())
        owner.stop()
    }

    @Test fun ownerStatusPublishesSamePeerRepeatedRequest() = runTest {
        val sockets = Sockets()
        val owner = owner(sockets)
        assertTrue(owner.start(Any(), "same label", null))
        val peer = Socket()
        sockets.listeners.last().incoming.send(peer)
        peer.input.send(hello() + message(0x10))
        runCurrent()
        val first = owner.status.value
        val request = assertNotNull(first.pendingControlRequest)
        owner.declinePendingControl(request)
        runCurrent()
        assertNull(owner.status.value.pendingControlRequest)
        peer.input.send(message(0x10))
        runCurrent()
        val next = owner.status.value
        assertEquals(first.pendingControlRequestName, next.pendingControlRequestName)
        val current = assertNotNull(next.pendingControlRequest)
        assertEquals(request.peer, current.peer)
        assertEquals(request.source, current.source)
        assertEquals(request.requestRevision + 1, current.requestRevision)
        assertNotEquals(first, next)
        owner.stop()
    }

    private fun TestScope.owner(sockets: Sockets): RelayBroadcastOwner<Any, Int, Int, Int, Int, Boolean, String> =
        RelayBroadcastOwner(scope = backgroundScope, codec = codec, hostName = "SIMULATED producer",
            frames = { MutableSharedFlow<Int>() }, stateChanges = { MutableSharedFlow<Unit>() },
            frame = { RelayBroadcastFrame(it, byteArrayOf()) }, readState = { _, _, _ -> 1 },
            dispatch = { _, _, _ -> }, makeAnnouncement = { object : RelayBroadcastAnnouncement {
                override fun start(port: Int, servedCameraHost: String?) {}
                override fun stop() {}
            } }, sockets = sockets, frameDispatcher = StandardTestDispatcher(testScheduler))
    private fun message(kind: Int, bytes: ByteArray = byteArrayOf()): ByteArray = RelayStreamFraming.encode(kind, bytes)
    private fun hello(): ByteArray = message(1, codec.encodeHello(RelayPeerHello(2, "SIMULATED watcher", watcherID = "saved")))
    private class Socket : RelayDuplex {
        val input = Channel<ByteArray>(Channel.UNLIMITED)
        val writes = mutableListOf<ByteArray>()
        override suspend fun receive(maximumBytes: Int): ByteArray? = input.receiveCatching().getOrNull()
        override suspend fun write(bytes: ByteArray) { writes += bytes.copyOf() }
        override fun close() { input.close() }
        fun controls(): List<Boolean> = writes.mapNotNull {
            val packet = requireNotNull(RelayStreamFraming.decode(it, RelayWireProfile.SHARED_MONITOR))
            if (packet.kind == 4) packet.payload.single() == 1.toByte() else null
        }
    }
    private class Listener : RelaySocketListener {
        override val port = 5555
        val incoming = Channel<RelayDuplex>(Channel.UNLIMITED)
        override suspend fun accept(): RelayDuplex = incoming.receive()
        override fun close() { incoming.close() }
    }
    private class Sockets : RelaySocketFactory {
        val listeners = mutableListOf<Listener>()
        override fun listen(preferredPort: Int): RelaySocketListener = Listener().also { listeners += it }
        override suspend fun connect(host: String, port: Int, timeoutMillis: Int): RelayDuplex = error("No active probe")
    }
    private class Codec : RelayControlWireCodec<Int, Int, Int, Boolean, String> {
        override val profile = RelayWireProfile("_simulated._tcp", 2, servedCameraTXTKey = "ch", watchableTXTKey = "w")
        override fun videoDescription(metadata: Int) = RelayVideoDescription(0, true, null)
        override fun encodeHello(hello: RelayPeerHello): ByteArray =
            "${hello.version}|${hello.hostName}|${hello.passcode.orEmpty()}|${hello.watcherID.orEmpty()}".toByteArray()
        override fun decodeHello(payload: ByteArray): RelayPeerHello = payload.toString(Charsets.UTF_8).split('|').let {
            RelayPeerHello(it[0].toInt(), it[1], passcode = it[2].ifEmpty { null }, watcherID = it[3].ifEmpty { null })
        }
        override fun encodeState(state: Int): ByteArray = byteArrayOf(state.toByte())
        override fun decodeState(payload: ByteArray): Int = payload.single().toInt()
        override fun encodeCommand(command: Int): ByteArray = byteArrayOf(command.toByte())
        override fun decodeCommand(payload: ByteArray): Int = payload.single().toInt()
        override fun encodeFrame(metadata: Int, image: ByteArray): ByteArray = RelayFrameBlob.encode(byteArrayOf(metadata.toByte()), image)
        override fun decodeFrame(payload: ByteArray): RelayFramePayload<Int> = RelayFrameBlob.decode(payload).let {
            RelayFramePayload(it.metadata.single().toInt(), it.image)
        }
        override fun encodeControl(holderName: String, holderIsRecipient: Boolean): ByteArray = byteArrayOf((if (holderIsRecipient) 1 else 0).toByte())
        override fun decodeControl(payload: ByteArray): Boolean = payload.single() == 1.toByte()
        override fun holderIsRecipient(control: Boolean): Boolean = control
        override fun encodeDenied(reason: String, passcodeRequired: Boolean): ByteArray = reason.toByteArray()
        override fun decodeDenied(payload: ByteArray): String = payload.toString(Charsets.UTF_8)
    }
}
