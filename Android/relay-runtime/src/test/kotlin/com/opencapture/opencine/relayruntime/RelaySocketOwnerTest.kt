package com.opencapture.opencine.relayruntime

import com.opencapture.opencine.relay.RelayControlWireCodec
import com.opencapture.opencine.relay.RelayFrameBlob
import com.opencapture.opencine.relay.RelayFramePayload
import com.opencapture.opencine.relay.RelayHostControl
import com.opencapture.opencine.relay.RelayPeerHello
import com.opencapture.opencine.relay.RelaySocketPolicy
import com.opencapture.opencine.relay.RelayStreamFraming
import com.opencapture.opencine.relay.RelayVideoDescription
import com.opencapture.opencine.relay.RelayWireProfile
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext

/** SIMULATED sockets expose real partial reads, suspended writes and noncooperative completions. */
@OptIn(ExperimentalCoroutinesApi::class)
class RelaySocketOwnerTest {
    private val codec = Codec()

    @Test fun clientPartialFramesControlRevisionAndHelloOrderingArePreserved() = runTest {
        val factory = Sockets()
        val socket = Socket()
        factory.connections.send(socket)
        val client = RelaySocketClient(backgroundScope, codec, factory)
        val events = mutableListOf<RelayClientEvent<Int, Int, Boolean, String>>()
        backgroundScope.launch { client.events.collect { events += it } }
        assertFalse(client.sendCommand(7))
        client.connect("host", 5555, RelayPeerHello(2, "watcher"))
        runCurrent()
        assertEquals(listOf(1), socket.kinds())
        val introduction = message(1, codec.encodeHello(RelayPeerHello(2, "producer")))
        socket.input.send(introduction.copyOfRange(0, 3))
        runCurrent()
        assertTrue(events.isEmpty())
        socket.input.send(introduction.copyOfRange(3, introduction.size) + message(4, byteArrayOf(1)))
        runCurrent()
        assertTrue(events[0] is RelayClientEvent.Connected)
        assertTrue(events[1] is RelayClientEvent.ControlChanged)
        val gate = CompletableDeferred<Unit>()
        socket.hold = { kind -> gate.takeIf { kind == 0x10 } }
        assertTrue(client.requestControl())
        runCurrent()
        assertTrue(client.sendCommand(7))
        socket.input.send(message(4, byteArrayOf(0)))
        runCurrent()
        gate.complete(Unit)
        runCurrent()
        assertEquals(listOf(1, 0x10), socket.kinds())
        assertFalse(client.sendCommand(8))
        val image = byteArrayOf(0, -1, 3)
        socket.input.send(message(3, codec.encodeFrame(9, image)))
        runCurrent()
        val frame = events.filterIsInstance<RelayClientEvent.FrameReceived<Int>>().single()
        assertEquals(9, frame.metadata)
        assertContentEquals(image, frame.image)
        assertEquals(client.currentSource, frame.source)
        client.stop()
        assertTrue(socket.closed)
    }

    @Test fun clientReplacementCannotAdoptAnOldConnectAndMalformedHeaderClosesOnlyCurrentSocket() = runTest {
        val factory = Sockets()
        val lateConnect = CompletableDeferred<RelayDuplex>()
        factory.delayedConnect = lateConnect
        val client = RelaySocketClient(backgroundScope, codec, factory)
        val events = mutableListOf<RelayClientEvent<Int, Int, Boolean, String>>()
        backgroundScope.launch { client.events.collect { events += it } }
        client.connect("old", 1, RelayPeerHello(2, "watcher"))
        runCurrent()
        val oldSource = client.currentSource
        factory.delayedConnect = null
        val current = Socket()
        factory.connections.send(current)
        client.connect("new", 2, RelayPeerHello(2, "watcher"))
        runCurrent()
        val abandoned = Socket()
        lateConnect.complete(abandoned)
        runCurrent()
        assertTrue(abandoned.closed)
        assertTrue(abandoned.writes.isEmpty())
        assertFalse(current.closed)
        assertTrue(client.currentSource != oldSource)
        current.input.send(byteArrayOf(-1, -1, -1, -1, 3))
        runCurrent()
        assertTrue(current.closed)
        assertEquals(1, events.filterIsInstance<RelayClientEvent.Closed>().size)
        assertEquals(client.currentSource, events.last().source)
        assertFalse(client.requestControl())
        client.stop()
    }

    @Test fun hostRefusedIdentityCannotRestoreParkedControlAndOldAdmissionCannotDispatch() = runTest {
        val sockets = Sockets()
        val host = RelaySocketHost(backgroundScope, codec, "producer", "camera", sockets,
            nowMillis = { testScheduler.currentTime })
        host.watcherPasscode = "secret"
        val commands = mutableListOf<Pair<Int, RelayHostControl.Admission>>()
        var pendingName: String? = null
        var holderName: String? = null
        host.onControlChanged = { pending, holder -> pendingName = pending; holderName = holder }
        host.onCommand = { command, admission -> commands += command to admission }
        assertTrue(host.start())
        val original = Socket()
        sockets.listener.incoming.send(original)
        runCurrent()
        original.input.send(hello("holder", "saved-id", "secret") + message(0x10))
        runCurrent()
        assertEquals("holder", pendingName)
        host.grantPendingControl()
        runCurrent()
        original.input.send(message(0x12, codec.encodeCommand(1)))
        runCurrent()
        val old = commands.single().second
        assertTrue(host.admits(old))
        original.input.close()
        runCurrent()
        assertFalse(host.admits(old))
        assertEquals("holder", holderName)

        val refused = Socket()
        sockets.listener.incoming.send(refused)
        runCurrent()
        refused.input.send(hello("pretender", "saved-id", "wrong") + message(0x10) + message(0x12, codec.encodeCommand(2)))
        runCurrent()
        assertTrue(5 in refused.kinds())
        assertNull(pendingName)
        assertEquals("holder", holderName)
        assertEquals(1, commands.size)
        val replacement = Socket()
        sockets.listener.incoming.send(replacement)
        runCurrent()
        replacement.input.send(hello("holder", "saved-id", "secret"))
        runCurrent()
        assertTrue(replacement.writes.any { packet -> decoded(packet).let { it.kind == 4 && it.payload.single() == 1.toByte() } })
        advanceTimeBy(20_000)
        runCurrent()
        assertEquals("holder", holderName)
        host.retireSource()
        assertFalse(host.admits(old))
        replacement.input.send(message(0x12, codec.encodeCommand(3)))
        runCurrent()
        assertEquals(1, commands.size)
        host.stop()
        assertNull(holderName)
        assertEquals(1, commands.size)
    }

    @Test fun hostSlowPeerRetainsExactTwoPendingFramesWithoutStarvingOtherPeerOrControl() = runTest {
        val sockets = Sockets()
        val host = RelaySocketHost(backgroundScope, codec, "producer", null, sockets)
        assertTrue(host.start())
        val slow = Socket()
        val fast = Socket()
        sockets.listener.incoming.send(slow)
        sockets.listener.incoming.send(fast)
        runCurrent()
        slow.input.send(hello("slow", "slow-id"))
        fast.input.send(hello("fast", "fast-id"))
        runCurrent()
        val gate = CompletableDeferred<Unit>()
        slow.hold = { kind -> gate.takeIf { kind == 3 } }
        host.broadcastFrame(1, byteArrayOf(1))
        runCurrent()
        for (id in 2..4) { host.broadcastFrame(id, byteArrayOf(id.toByte())); runCurrent() }
        assertEquals(listOf(1, 2, 3, 4), fast.frames())
        assertTrue(slow.frames().isEmpty())
        slow.input.send(message(0x10))
        runCurrent()
        host.grantPendingControl()
        runCurrent()
        gate.complete(Unit)
        runCurrent()
        assertEquals(listOf(1, 3, 4), slow.frames())
        val kinds = slow.kinds()
        val firstFrame = kinds.indexOf(3)
        assertEquals(4, kinds[firstFrame + 1])
        host.stop()
    }

    @Test fun hostPartialOversizedAndUnknownReadsRetirePeerWithoutCommandsAndCloseSendsNone() = runTest {
        val sockets = Sockets()
        val host = RelaySocketHost(backgroundScope, codec, "producer", null, sockets)
        var calls = 0
        host.onCommand = { _, _ -> calls += 1 }
        host.start()
        val partial = Socket()
        sockets.listener.incoming.send(partial)
        runCurrent()
        val introduction = hello("holder", "saved-id") + message(0x10)
        partial.input.send(introduction.copyOfRange(0, 4))
        runCurrent()
        assertFalse(partial.closed)
        partial.input.send(introduction.copyOfRange(4, introduction.size))
        runCurrent()
        host.grantPendingControl()
        partial.input.send(byteArrayOf(0, 0, 0, 1, 0x7F))
        runCurrent()
        assertTrue(partial.closed)
        val oversized = Socket()
        sockets.listener.incoming.send(oversized)
        runCurrent()
        oversized.input.send(byteArrayOf(-1, -1, -1, -1, 3))
        runCurrent()
        assertTrue(oversized.closed)
        assertEquals(0, calls)
        host.stop()
        assertEquals(0, calls)
    }

    @Test fun hostParkedExpiryAndOldCourtesyStopCannotClearSuccessorCallbacks() = runTest {
        val sockets = Sockets()
        val host = RelaySocketHost(backgroundScope, codec, "producer", null, sockets,
            policy = RelaySocketPolicy(courtesyCloseMillis = 150), nowMillis = { testScheduler.currentTime })
        var holder: String? = null
        val counts = mutableListOf<Int>()
        host.onControlChanged = { _, value -> holder = value }
        host.onPeerCountChanged = counts::add
        host.start()
        val first = Socket()
        sockets.listener.incoming.send(first)
        runCurrent()
        first.input.send(hello("holder", "saved-id") + message(0x10))
        runCurrent()
        host.grantPendingControl()
        first.input.close()
        runCurrent()
        assertEquals("holder", holder)
        advanceTimeBy(19_999)
        runCurrent()
        assertEquals("holder", holder)
        advanceTimeBy(1)
        runCurrent()
        assertNull(holder)
        val second = Socket()
        sockets.listener.incoming.send(second)
        runCurrent()
        backgroundScope.launch { host.stop(notifyingViewers = "ended") }
        runCurrent()
        sockets.listener = Listener()
        host.start()
        val third = Socket()
        sockets.listener.incoming.send(third)
        runCurrent()
        assertEquals(1, counts.last())
        advanceTimeBy(150)
        runCurrent()
        assertTrue(second.closed)
        assertFalse(third.closed)
        assertEquals(1, counts.last())
        host.stop()
    }

    private fun message(kind: Int, payload: ByteArray = ByteArray(0)): ByteArray = RelayStreamFraming.encode(kind, payload)
    private fun hello(name: String, identity: String, passcode: String? = null): ByteArray =
        message(1, codec.encodeHello(RelayPeerHello(2, name, passcode = passcode, watcherID = identity)))
    private fun decoded(bytes: ByteArray): RelayStreamFraming.Decoded = assertNotNull(RelayStreamFraming.decode(bytes, codec.profile))
    private inner class Socket : RelayDuplex {
        val input = Channel<ByteArray>(Channel.UNLIMITED)
        val writes = mutableListOf<ByteArray>()
        var closed = false
        var hold: (Int) -> CompletableDeferred<Unit>? = { null }
        override suspend fun receive(maximumBytes: Int): ByteArray? = input.receiveCatching().getOrNull()?.also {
            require(it.size <= maximumBytes)
        }
        override suspend fun write(bytes: ByteArray) {
            hold(decoded(bytes).kind)?.await()
            check(!closed)
            writes += bytes.copyOf()
        }
        override fun close() { closed = true; input.close() }
        fun kinds(): List<Int> = writes.map { decoded(it).kind }
        fun frames(): List<Int> = writes.map(::decoded).filter { it.kind == 3 }.map { codec.decodeFrame(it.payload).metadata }
    }
    private class Listener : RelaySocketListener {
        override val port: Int = 5555
        val incoming = Channel<RelayDuplex>(Channel.UNLIMITED)
        override suspend fun accept(): RelayDuplex = incoming.receive()
        override fun close() { incoming.close() }
    }
    private class Sockets : RelaySocketFactory {
        var listener = Listener()
        val connections = Channel<RelayDuplex>(Channel.UNLIMITED)
        var delayedConnect: CompletableDeferred<RelayDuplex>? = null
        override fun listen(preferredPort: Int): RelaySocketListener = listener
        override suspend fun connect(host: String, port: Int, timeoutMillis: Int): RelayDuplex {
            val delayed = delayedConnect
            return if (delayed != null) withContext(NonCancellable) { delayed.await() } else connections.receive()
        }
    }
    private class Codec : RelayControlWireCodec<Int, Int, Int, Boolean, String> {
        override val profile: RelayWireProfile = RelayWireProfile("_simulated._tcp", 2, servedCameraTXTKey = "ch", watchableTXTKey = "w")
        override fun videoDescription(metadata: Int): RelayVideoDescription = RelayVideoDescription(0, true, null)
        override fun encodeHello(hello: RelayPeerHello): ByteArray =
            "${hello.version}|${hello.hostName}|${hello.passcode.orEmpty()}|${hello.watcherID.orEmpty()}".toByteArray()
        override fun decodeHello(payload: ByteArray): RelayPeerHello {
            val fields = payload.toString(Charsets.UTF_8).split('|')
            require(fields.size == 4)
            return RelayPeerHello(fields[0].toInt(), fields[1], passcode = fields[2].ifEmpty { null }, watcherID = fields[3].ifEmpty { null })
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
