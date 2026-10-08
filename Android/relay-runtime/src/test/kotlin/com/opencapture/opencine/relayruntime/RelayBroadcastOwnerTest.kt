package com.opencapture.opencine.relayruntime

import com.opencapture.opencine.relay.RelayControlWireCodec
import com.opencapture.opencine.relay.RelayFrameBlob
import com.opencapture.opencine.relay.RelayFramePayload
import com.opencapture.opencine.relay.RelayPeerHello
import com.opencapture.opencine.relay.RelayStreamFraming
import com.opencapture.opencine.relay.RelayVideoDescription
import com.opencapture.opencine.relay.RelayWireProfile
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** SIMULATED native/announcement ports drive the actual socket host and subscription owner. */
@OptIn(ExperimentalCoroutinesApi::class)
class RelayBroadcastOwnerTest {
    private val codec = Codec()
    private class Source(val name: String, var reading: Int) {
        val pictures = MutableSharedFlow<RelayBroadcastFrame<Int>>(extraBufferCapacity = 4)
        val changes = MutableSharedFlow<Unit>(extraBufferCapacity = 4)
    }
    private class Announcement : RelayBroadcastAnnouncement {
        val starts = mutableListOf<Pair<Int, String?>>()
        var stops = 0
        var onStop: (() -> Unit)? = null
        override fun start(port: Int, servedCameraHost: String?) { starts += port to servedCameraHost }
        override fun stop() { stops += 1; onStop?.invoke() }
    }
    private inner class Rig(scope: TestScope) {
        val sockets = Sockets()
        val announcements = mutableListOf<Announcement>()
        val dispatched = mutableListOf<Pair<Source, Int>>()
        val admissions = mutableListOf<RelayBroadcastDispatch>()
        var dispatchWait: CompletableDeferred<Unit>? = null
        var readFrame: (RelayBroadcastFrame<Int>) -> RelayBroadcastFrame<Int> = { it }
        val owner = RelayBroadcastOwner<Source, RelayBroadcastFrame<Int>, Int, Int, Int, Boolean, String>(
            scope = scope.backgroundScope, codec = codec, hostName = "SIMULATED producer",
            frames = { it.pictures }, stateChanges = { it.changes }, frame = { readFrame(it) },
            readState = { source, _, _ -> source.reading },
            dispatch = { source, command, admission ->
                admissions += admission
                dispatchWait?.await()
                // The integration performs this check at its real queued camera boundary.
                if (admission.isCurrent()) dispatched += source to command
            },
            makeAnnouncement = { Announcement().also { announcements += it } },
            sockets = sockets, frameDispatcher = StandardTestDispatcher(scope.testScheduler),
        )
        suspend fun peer(passcode: String? = null): Socket {
            val peer = Socket()
            sockets.listeners.last().incoming.send(peer)
            peer.input.send(message(1, codec.encodeHello(RelayPeerHello(2, "SIMULATED watcher",
                passcode = passcode, watcherID = "saved-id"))))
            return peer
        }
    }

    @Test fun actualSubscriptionsForwardExactPictureAndStateAndCloseWithoutCameraCommands() = runTest {
        val rig = Rig(this)
        val source = Source("camera", 7)
        assertTrue(rig.owner.start(source, source.name, "192.0.2.7"))
        runCurrent()
        val peer = rig.peer()
        runCurrent()
        assertEquals(listOf<Pair<Int, String?>>(5555 to "192.0.2.7"), rig.announcements.single().starts)
        assertTrue(rig.owner.status.value.isBroadcasting)
        assertEquals(1, rig.owner.status.value.watcherCount)
        assertEquals(7, peer.messages().last { it.kind == 2 }.payload.single().toInt())
        val image = byteArrayOf(-1, -40, 0, 9, -1, -39)
        source.pictures.emit(RelayBroadcastFrame(17, image, 29.97))
        source.reading = 9
        source.changes.emit(Unit)
        runCurrent()
        val decoded = codec.decodeFrame(peer.messages().single { it.kind == 3 }.payload)
        assertEquals(17, decoded.metadata)
        assertContentEquals(image, decoded.image)
        assertEquals(9, peer.messages().last { it.kind == 2 }.payload.single().toInt())
        rig.owner.stop()
        runCurrent()
        assertTrue(peer.closed)
        assertEquals(1, rig.announcements.single().stops)
        assertFalse(rig.owner.status.value.isBroadcasting)
        assertTrue(rig.dispatched.isEmpty())
    }

    @Test fun refusalAndRevokedNativeWaitersCannotDispatchIntoSourceOrSuccessor() = runTest {
        val rig = Rig(this)
        val source = Source("same label", 1)
        rig.owner.watcherPasscode = "secret"
        assertTrue(rig.owner.start(source, source.name, null))
        runCurrent()
        val refused = rig.peer("wrong")
        refused.input.send(message(0x10) + message(0x12, byteArrayOf(8)))
        runCurrent()
        assertTrue(rig.admissions.isEmpty())
        assertTrue(rig.dispatched.isEmpty())
        val holder = rig.peer("secret")
        holder.input.send(message(0x10))
        runCurrent()
        rig.owner.grantPendingControl()
        runCurrent()
        holder.input.send(message(0x12, byteArrayOf(6)))
        runCurrent()
        assertEquals(listOf(source to 6), rig.dispatched)
        rig.admissions.clear()
        val nativeWait = CompletableDeferred<Unit>()
        rig.dispatchWait = nativeWait
        holder.input.send(message(0x12, byteArrayOf(9)))
        runCurrent()
        val admitted = rig.admissions.single()
        assertTrue(admitted.isCurrent())
        rig.owner.reclaimControl()
        runCurrent()
        assertFalse(admitted.isCurrent())
        val successor = Source("same label", 2)
        assertTrue(rig.owner.start(successor, successor.name, null))
        runCurrent()
        nativeWait.complete(Unit)
        runCurrent()
        assertEquals(listOf(source to 6), rig.dispatched)
        assertFalse(admitted.isCurrent())
        assertTrue(rig.owner.status.value.isBroadcasting)
        assertEquals(0, rig.owner.status.value.watcherCount)
        rig.owner.stop()
        runCurrent()
    }

    @Test fun anOuterStartCannotReplaceASuccessorStartedDuringOldAnnouncementRetirement() = runTest {
        val rig = Rig(this)
        val original = Source("same label", 1)
        val successor = Source("same label", 2)
        val outer = Source("same label", 3)
        assertTrue(rig.owner.start(original, original.name, null))
        runCurrent()
        rig.announcements.single().onStop = {
            rig.announcements.first().onStop = null
            assertTrue(rig.owner.start(successor, successor.name, null))
        }
        assertFalse(rig.owner.start(outer, outer.name, null))
        runCurrent()
        val peer = rig.peer()
        runCurrent()
        assertEquals(2, peer.messages().last { it.kind == 2 }.payload.single().toInt())
        outer.pictures.emit(RelayBroadcastFrame(3, byteArrayOf(3)))
        successor.pictures.emit(RelayBroadcastFrame(2, byteArrayOf(2)))
        runCurrent()
        assertEquals(listOf(2), peer.messages().filter { it.kind == 3 }.map { codec.decodeFrame(it.payload).metadata })
        rig.owner.stop()
        runCurrent()
    }

    @Test fun replacementDuringPictureConversionRefusesOldPictureAndOldSourceChanges() = runTest {
        val rig = Rig(this)
        val old = Source("same label", 1)
        val successor = Source("same label", 2)
        assertTrue(rig.owner.start(old, old.name, null))
        runCurrent()
        val oldPeer = rig.peer()
        runCurrent()
        rig.readFrame = { input ->
            rig.readFrame = { it }
            assertTrue(rig.owner.start(successor, successor.name, null))
            input
        }
        old.pictures.emit(RelayBroadcastFrame(1, byteArrayOf(1)))
        runCurrent()
        assertTrue(oldPeer.messages().none { it.kind == 3 })
        val currentPeer = rig.peer()
        runCurrent()
        old.reading = 8
        old.changes.emit(Unit)
        successor.pictures.emit(RelayBroadcastFrame(2, byteArrayOf(2)))
        runCurrent()
        assertEquals(2, currentPeer.messages().last { it.kind == 2 }.payload.single().toInt())
        assertEquals(listOf(2), currentPeer.messages().filter { it.kind == 3 }.map { codec.decodeFrame(it.payload).metadata })
        rig.owner.stop()
        runCurrent()
    }

    private class Socket : RelayDuplex {
        val input = Channel<ByteArray>(Channel.UNLIMITED)
        val writes = mutableListOf<ByteArray>()
        var closed = false
        override suspend fun receive(maximumBytes: Int): ByteArray? = input.receiveCatching().getOrNull()
        override suspend fun write(bytes: ByteArray) { check(!closed); writes += bytes.copyOf() }
        override fun close() { closed = true; input.close() }
        fun messages(): List<RelayStreamFraming.Decoded> = writes.map {
            requireNotNull(RelayStreamFraming.decode(it, RelayWireProfile.SHARED_MONITOR))
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
    private fun message(kind: Int, bytes: ByteArray = byteArrayOf()): ByteArray = RelayStreamFraming.encode(kind, bytes)
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
