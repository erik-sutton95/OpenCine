package com.opencapture.opencine.relayruntime

import com.opencapture.opencine.relay.RelayBroadcast
import com.opencapture.opencine.relay.RelayWireProfile
import java.io.IOException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ClosedReceiveChannelException
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
public class RelayDiscoveryRuntimeTest {
    @Test public fun retiredAcceptCannotBorrowNewPresenceAndStopClosesActualPeer(): Unit = runTest {
        val listeners = mutableListOf<Listener>()
        val ports = mutableListOf<Int>()
        val owner = RelayPassiveListener(15741, this, UnconfinedTestDispatcher(testScheduler),
            listen = { port -> ports.add(port); Listener(port).also(listeners::add) })
        val firstBytes = byteArrayOf(1)
        assertEquals(15741, owner.update(firstBytes))
        firstBytes[0] = 9
        owner.stop()
        assertTrue(listeners[0].closed)
        owner.update(byteArrayOf(2))
        val oldPeer = Peer()
        listeners[0].accepted.send(oldPeer)
        assertTrue(oldPeer.closed)
        assertTrue(oldPeer.writes.isEmpty())
        val next = Peer(blockWrite = true)
        listeners[1].accepted.send(next)
        assertEquals(listOf(2), next.writes.map { it.single().toInt() })
        owner.stop()
        assertTrue(next.closed && listeners[1].closed)
        next.release.complete(Unit)
        listeners[1].accepted.close()
        assertEquals(listOf(15741, 15741), ports)
    }
    @Test public fun presenceUpdatesCopyPayloadAndBeaconOnlyClosesWithoutAnyProbe(): Unit = runTest {
        val listener = Listener(5070)
        val owner = RelayPassiveListener(0, this, UnconfinedTestDispatcher(testScheduler), listen = { listener })
        val bytes = byteArrayOf(3)
        owner.update(bytes)
        bytes[0] = 8
        val first = Peer()
        listener.accepted.send(first)
        assertEquals(listOf(3), first.writes.map { it.single().toInt() })
        owner.update(byteArrayOf())
        val beacon = Peer()
        listener.accepted.send(beacon)
        assertTrue(beacon.closed && beacon.writes.isEmpty())
        owner.stop()
        listener.accepted.close()
    }
    @Test public fun fixedPresenceBindFailureNeverFallsBackOrAdvertisesAJoinablePort(): Unit = runTest {
        val ports = mutableListOf<Int>()
        var failures = 0
        val owner = RelayPassiveListener(15741, this, UnconfinedTestDispatcher(testScheduler),
            listen = { ports.add(it); throw IOException("occupied") }, onBindFailure = { failures++ })
        assertEquals(null, owner.update(byteArrayOf(1)))
        assertEquals(listOf(15741), ports)
        assertEquals(1, failures)
        owner.stop()
        assertEquals(1, failures)
    }
    @Test public fun oldRegistrationAndStopBeforeHandleReturnWithdrawOnlyTheirOwnProducer(): Unit {
        class Handle : RelayServiceRegistration { var stops = 0; override fun stop() { stops++ } }
        val handles = mutableListOf<Handle>()
        val completions = mutableListOf<() -> Unit>()
        val facts = mutableMapOf("ch" to "camera")
        val value = RelayServiceAdvertisement("Self", "_test._tcp", 5000, facts)
        facts["ch"] = "changed"
        val owner = RelayAdvertisementOwner { received, complete ->
            assertEquals("camera", received.attributes["ch"])
            completions.add(complete)
            Handle().also(handles::add)
        }
        owner.register(value)
        owner.register(value)
        assertEquals(1, handles[0].stops)
        completions[0]()
        assertEquals(2, handles[0].stops)
        assertEquals(0, handles[1].stops)
        owner.stop()
        completions[1]()
        assertEquals(2, handles[1].stops)
        lateinit var reentrant: RelayAdvertisementOwner
        val early = Handle()
        reentrant = RelayAdvertisementOwner { _, complete -> reentrant.stop(); complete(); early }
        reentrant.register(value)
        assertEquals(1, early.stops)
    }
    @Test public fun eachPassiveListingOwnsItsWindowAndLostResolutionCannotRestoreRetiredShield(): Unit = runTest {
        val profile = RelayWireProfile("_test._tcp", 2, servedCameraTXTKey = "ch", watchableTXTKey = "w")
        val events = MutableSharedFlow<RelayServiceEvent>()
        val owner = RelayServiceDirectory(profile)
        val values = mutableListOf<List<RelayBroadcast>>()
        val first = launch(UnconfinedTestDispatcher(testScheduler)) { owner.broadcasts(events).collect { values.add(it) } }
        events.emit(RelayServiceEvent.Resolved("Held in-use", "h1", 5000, mapOf("ch" to "camera", "w" to "0")))
        assertFalse(values.last().single().isWatchable)
        assertEquals("camera", values.last().single().servedCameraHost)
        events.emit(RelayServiceEvent.Lost("Held in-use"))
        events.emit(RelayServiceEvent.Resolved("Held in-use", "old", 5000, mapOf("ch" to "camera")))
        assertEquals(emptyList(), values.last())
        first.cancel()
        val oldCount = values.size
        events.emit(RelayServiceEvent.Resolved("Old", "old", 5000, emptyMap()))
        assertEquals(oldCount, values.size)
        val second = launch(UnconfinedTestDispatcher(testScheduler)) { owner.broadcasts(events).collect { values.add(it) } }
        assertEquals(emptyList(), values.last())
        events.emit(RelayServiceEvent.Found("Held in-use"))
        events.emit(RelayServiceEvent.Resolved("Held in-use", "replacement", 5001, mapOf("ch" to "new-camera", "w" to "0")))
        assertEquals(listOf(RelayBroadcast("Held in-use", "replacement", 5001, "new-camera", false)), values.last())
        second.cancel()
    }

    private class Listener(override val port: Int) : RelaySocketListener {
        val accepted = Channel<RelayDuplex>(Channel.UNLIMITED)
        var closed = false
        override suspend fun accept(): RelayDuplex = withContext(NonCancellable) {
            try { accepted.receive() } catch (_: ClosedReceiveChannelException) { throw IOException("closed") }
        }
        override fun close() { closed = true }
    }
    private class Peer(private val blockWrite: Boolean = false) : RelayDuplex {
        val writes = mutableListOf<ByteArray>()
        val release = CompletableDeferred<Unit>()
        var closed = false
        override suspend fun receive(maximumBytes: Int): ByteArray? = null
        override suspend fun write(bytes: ByteArray) { writes.add(bytes.copyOf()); if (blockWrite) release.await() }
        override fun close() { closed = true }
    }
}
