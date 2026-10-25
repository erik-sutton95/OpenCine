package com.opencapture.opencine.relayruntime

import com.opencapture.opencine.relay.RelayControlWireCodec
import com.opencapture.opencine.relay.RelayFramePayload
import com.opencapture.opencine.relay.RelayPeerHello
import com.opencapture.opencine.relay.RelayVideoDescription
import com.opencapture.opencine.relay.RelayWireProfile
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.FlowCollector
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

@OptIn(ExperimentalCoroutinesApi::class, InternalCoroutinesApi::class)
class RelayViewerOwnerTest {
    private class Credentials : RelayViewerCredentials {
        val passcodes: MutableMap<String, String> = mutableMapOf()
        override var jpegOnly: Boolean = false
        var latches: Int = 0
        override fun passcode(key: String): String? = passcodes[key]
        override fun rememberPasscode(key: String, code: String): Unit { passcodes[key] = code }
        override fun latchJpegOnly(): Unit { jpegOnly = true; latches += 1 }
    }
    /** Can deliver a genuinely late callback even after its old collection job is canceled. */
    private class LateEvents : Flow<RelayClientEvent<Int, Int, Boolean, RelayViewerRefusal>> {
        private val listeners: MutableList<FlowCollector<RelayClientEvent<Int, Int, Boolean, RelayViewerRefusal>>> = mutableListOf()
        override suspend fun collect(collector: FlowCollector<RelayClientEvent<Int, Int, Boolean, RelayViewerRefusal>>): Nothing {
            listeners += collector
            awaitCancellation()
        }
        suspend fun send(event: RelayClientEvent<Int, Int, Boolean, RelayViewerRefusal>): Unit {
            listeners.toList().forEach { it.emit(event) }
        }
    }
    private class Client : RelayViewerConnection<Int, Int, Int, Boolean, RelayViewerRefusal> {
        override var currentSource: UUID = UUID.randomUUID()
        override val events: LateEvents = LateEvents()
        val hellos: MutableList<RelayPeerHello> = mutableListOf()
        val commands: MutableList<Int> = mutableListOf()
        var requests: Int = 0
        var releases: Int = 0
        var stops: Int = 0
        var stopped: Boolean = false
        var allowCommand: Boolean = true
        var onConnect: (() -> Unit)? = null
        var onStop: (() -> Unit)? = null
        var stopWait: CompletableDeferred<Unit>? = null
        override fun connect(host: String, port: Int, hello: RelayPeerHello): Unit { hellos += hello; onConnect?.invoke() }
        override fun requestControl(): Boolean { requests += 1; return !stopped }
        override fun releaseControl(): Boolean { releases += 1; return !stopped }
        override fun sendCommand(command: Int): Boolean {
            if (stopped || !allowCommand) return false
            commands += command
            return true
        }
        override suspend fun stop(): Unit {
            stopped = true; currentSource = UUID.randomUUID(); stops += 1
            onStop?.invoke(); stopWait?.await()
        }
    }
    private class PictureDecoder : RelayPictureDecoder<Int> {
        var produces: Boolean = true
        var exhausted: Boolean = false
        var closes: Int = 0
        var beforeDecode: (() -> Unit)? = null
        override fun beginSource(source: UUID): Unit {}
        override fun decode(source: UUID, metadata: Int, bytes: ByteArray): RelayPictureDecode {
            beforeDecode?.invoke()
            return RelayPictureDecode(if (produces) bytes else null, exhausted)
        }
        override fun retireSource(source: UUID): Unit {}
        override fun close(): Unit { closes += 1 }
    }
    private inner class Rig(scope: TestScope, policy: RelayViewerPolicy = RelayViewerPolicy()) {
        val credentials: Credentials = Credentials()
        val clients: MutableList<Client> = mutableListOf()
        val decoder: PictureDecoder = PictureDecoder()
        val pictures: RelayDecodedPictureOwner<Int, ByteArray> = RelayDecodedPictureOwner(decoder, { _, bytes, _ -> bytes })
        val readings: MutableList<Int> = mutableListOf()
        val names: MutableList<String> = mutableListOf()
        val logs: MutableList<String> = mutableListOf()
        var onCreate: (() -> Unit)? = null
        var onSource: (() -> Unit)? = null
        var onState: ((Int) -> Unit)? = null
        var onLatched: (() -> Unit)? = null
        val owner: RelayViewerOwner<Int, Int, Int, Boolean, RelayViewerRefusal, ByteArray> = RelayViewerOwner(
            scope = scope.backgroundScope, codec = Wire(),
            configuration = RelayViewerConfiguration("192.0.2.1", 15742, "SIMULATED watcher", "host-key", "saved-watcher"),
            facts = object : RelayViewerFacts<Int, Int, Boolean, RelayViewerRefusal> {
                override fun allowsControlRequests(state: Int): Boolean? = if (state == 0) null else state > 0
                override fun holderName(control: Boolean): String? = if (control) "SIMULATED watcher" else null
                override fun refusal(denied: RelayViewerRefusal): RelayViewerRefusal = denied
                override fun focusCoordinates(metadata: Int): RelayViewerFocusCoordinates? = if (metadata == 0) RelayViewerFocusCoordinates(640, 480) else null
            },
            picture = pictures, credentials = credentials, policy = policy,
            dispatcher = StandardTestDispatcher(scope.testScheduler), nowMillis = { scope.testScheduler.currentTime },
            onSourceBegan = { onSource?.invoke() }, onConnected = { _, hello -> names += hello.cameraName ?: hello.hostName },
            onState = { _, state -> readings += state; onState?.invoke(state) }, onJpegOnlyLatched = { onLatched?.invoke() },
            log = { logs += it }, makeConnection = {
                val client = Client().also { clients += it }
                onCreate?.invoke()
                client
            },
        )
        suspend fun connected(client: Client = clients.last()): Unit =
            client.events.send(RelayClientEvent.Connected(RelayPeerHello(1, "host", "camera"), client.currentSource))
        suspend fun frame(codec: Int, client: Client = clients.last()): Unit =
            client.events.send(RelayClientEvent.FrameReceived(codec, byteArrayOf(7), client.currentSource))
    }

    @Test fun actualCurrentJoinPreservesCredentialsReadingsPictureAndControlAndNoCloseCommands() = runTest {
        val rig = Rig(this)
        rig.credentials.passcodes["host-key"] = "code"
        rig.credentials.jpegOnly = true
        rig.owner.start()
        val client = rig.clients.single()
        assertEquals("code", client.hellos.single().passcode)
        assertEquals("saved-watcher", client.hellos.single().watcherID)
        assertEquals(listOf("jpeg"), client.hellos.single().codecs)
        assertFalse(rig.owner.sendCommand(1))
        rig.connected()
        client.events.send(RelayClientEvent.StateReceived(5, client.currentSource))
        client.events.send(RelayClientEvent.ControlChanged(true, client.currentSource))
        rig.frame(0)
        assertEquals(RelayViewerPhase.WATCHING, rig.owner.status.value.phase)
        assertEquals(listOf("camera"), rig.names)
        assertEquals(listOf(5), rig.readings)
        assertContentEquals(byteArrayOf(7), rig.pictures.publications.replayCache.single().frame)
        assertTrue(rig.owner.requestControl())
        assertTrue(rig.owner.releaseControl())
        assertTrue(rig.owner.sendCommand(8))
        assertEquals(listOf(8), client.commands)
        client.events.send(RelayClientEvent.ControlChanged(false, client.currentSource))
        assertFalse(rig.owner.sendCommand(9))
        rig.owner.stop()
        assertFalse(rig.owner.sendCommand(10))
        rig.owner.retry(); rig.owner.start()
        runCurrent()
        assertEquals(1, rig.clients.size)
        assertEquals(listOf(8), client.commands)
        assertEquals(1, rig.decoder.closes)
    }

    @Test fun decodeDeadlineUsesActualSourceEvidenceAndTheExactSixSecondBudget() = runTest {
        val rig = Rig(this)
        rig.decoder.produces = false
        rig.owner.start(); rig.connected(); rig.frame(1)
        runCurrent()
        advanceTimeBy(5_999); runCurrent()
        assertFalse(rig.credentials.jpegOnly)
        assertEquals(1, rig.clients.size)
        advanceTimeBy(1); runCurrent()
        assertTrue(rig.credentials.jpegOnly)
        assertEquals(1, rig.credentials.latches)
        assertEquals(2, rig.clients.size)
        assertEquals(listOf("jpeg"), rig.clients.last().hellos.single().codecs)
        assertEquals("no decoded frame within 6000 ms; rejoining for JPEG frames", rig.logs.single())
        rig.owner.stop()
    }

    @Test fun oldDecodeDeadlineAndExhaustionCannotDemoteAHealthyReplacementEvenAfterCanceledCallback() = runTest {
        val rig = Rig(this)
        rig.decoder.produces = false
        rig.owner.start(); rig.connected(); rig.frame(1)
        val old = rig.clients.single()
        val source = old.currentSource
        runCurrent(); advanceTimeBy(3_000)
        rig.owner.retry(); runCurrent()
        rig.decoder.produces = true
        rig.connected(); rig.frame(1)
        old.events.send(RelayClientEvent.FrameReceived(1, byteArrayOf(99), source))
        old.events.send(RelayClientEvent.StateReceived(99, source))
        old.events.send(RelayClientEvent.ControlChanged(true, source))
        advanceTimeBy(3_000); runCurrent()
        assertFalse(rig.credentials.jpegOnly)
        assertEquals(0, rig.credentials.latches)
        assertEquals(2, rig.clients.size)
        assertTrue(rig.readings.isEmpty())
        assertFalse(rig.owner.status.value.holdsControl)
        assertContentEquals(byteArrayOf(7), rig.pictures.publications.replayCache.single().frame)
        rig.owner.stop()
    }

    @Test fun receiptClockAndThreeSecondPollPreserveEightSecondStallAndThreeSecondRejoin() = runTest {
        val rig = Rig(this)
        rig.decoder.produces = false
        rig.owner.start(); rig.connected()
        runCurrent(); advanceTimeBy(6_000); runCurrent()
        assertEquals(RelayViewerPhase.WATCHING, rig.owner.status.value.phase)
        rig.frame(0)
        advanceTimeBy(8_999); runCurrent()
        assertEquals(RelayViewerPhase.WATCHING, rig.owner.status.value.phase)
        advanceTimeBy(1); runCurrent()
        assertEquals(RelayViewerPhase.FAILED, rig.owner.status.value.phase)
        assertEquals("The stream stalled. Reconnecting.", rig.owner.status.value.failureReason)
        advanceTimeBy(2_999); runCurrent()
        assertEquals(1, rig.clients.size)
        advanceTimeBy(1); runCurrent()
        assertEquals(2, rig.clients.size)
        assertFalse(rig.credentials.jpegOnly, "Receipt stall is separate from HEVC decode evidence")
        rig.owner.stop()
    }

    @Test fun denialPasscodeAndIntentionalEndCannotArmRejoinOrReuseOldControl() = runTest {
        val rig = Rig(this)
        rig.owner.start()
        var client = rig.clients.single()
        client.events.send(RelayClientEvent.JoinDenied(RelayViewerRefusal("code required", true), client.currentSource))
        client.events.send(RelayClientEvent.Closed(null, client.currentSource))
        assertEquals(RelayViewerPhase.DENIED, rig.owner.status.value.phase)
        assertTrue(rig.owner.status.value.needsPasscode)
        assertFalse(rig.owner.status.value.passcodeWasWrong)
        advanceTimeBy(10_000); runCurrent()
        assertEquals(1, rig.clients.size)
        rig.owner.submitPasscode("  approved  "); runCurrent()
        client = rig.clients.last()
        assertEquals("approved", rig.credentials.passcodes["host-key"])
        assertEquals("approved", client.hellos.single().passcode)
        client.events.send(RelayClientEvent.JoinDenied(RelayViewerRefusal("wrong code", true), client.currentSource))
        assertTrue(rig.owner.status.value.passcodeWasWrong)
        rig.owner.retry(); runCurrent(); client = rig.clients.last()
        rig.connected(client)
        client.events.send(RelayClientEvent.ControlChanged(true, client.currentSource))
        client.events.send(RelayClientEvent.JoinDenied(RelayViewerRefusal("operator ended", false), client.currentSource))
        client.events.send(RelayClientEvent.Closed("late close", client.currentSource))
        assertTrue(rig.owner.status.value.endedByBroadcaster)
        assertFalse(rig.owner.sendCommand(3))
        advanceTimeBy(30_000); runCurrent()
        assertEquals(3, rig.clients.size)
        rig.owner.stop()
    }

    @Test fun replacementDuringNativeDecodeAndLateClientStopCannotResetOrCloseTheSuccessor() = runTest {
        val rig = Rig(this)
        rig.owner.start(); rig.connected()
        val old = rig.clients.single()
        old.stopWait = CompletableDeferred()
        rig.decoder.beforeDecode = { rig.decoder.beforeDecode = null; rig.owner.start() }
        rig.frame(0, old)
        rig.connected(); rig.frame(0)
        val source = rig.owner.sourceToken
        old.stopWait?.complete(Unit)
        runCurrent()
        assertEquals(source, rig.pictures.currentSource)
        assertEquals(RelayViewerPhase.WATCHING, rig.owner.status.value.phase)
        assertFalse(rig.clients.last().stopped)
        assertContentEquals(byteArrayOf(7), rig.pictures.publications.replayCache.single().frame)
        rig.owner.stop()
    }

    @Test fun reentrantFactoryCannotOverwriteASuccessorAndCloseWhileStoppingRetiresNativeImmediately() = runTest {
        val rig = Rig(this)
        rig.onCreate = { rig.onCreate = null; rig.owner.start() }
        rig.owner.start()
        assertEquals(2, rig.clients.size)
        assertTrue(rig.clients.first().stopped)
        assertTrue(rig.clients.first().hellos.isEmpty())
        rig.connected()
        val client = rig.clients.last()
        val old = client.currentSource
        val close = CompletableDeferred<Unit>()
        client.stopWait = close
        val stopping = backgroundScope.launch { rig.owner.stop() }
        runCurrent()
        assertEquals(1, rig.decoder.closes)
        client.events.send(RelayClientEvent.StateReceived(99, old))
        client.events.send(RelayClientEvent.ControlChanged(true, old))
        assertTrue(rig.readings.isEmpty())
        assertFalse(rig.owner.sendCommand(4))
        close.complete(Unit); stopping.join()
        assertTrue(client.commands.isEmpty())
    }

    @Test fun capturedCommandCannotBorrowARegrantedPeerOrReplacementSourceAndCurrentCommandsStillSend() = runTest {
        val rig = Rig(this)
        rig.owner.start(); rig.connected()
        val old = rig.clients.single()
        old.events.send(RelayClientEvent.ControlChanged(true, old.currentSource))
        val first = requireNotNull(rig.owner.commandAdmission())
        assertTrue(rig.owner.sendCommand(1, first))
        old.events.send(RelayClientEvent.ControlChanged(false, old.currentSource))
        old.events.send(RelayClientEvent.ControlChanged(true, old.currentSource))
        assertFalse(rig.owner.sendCommand(2, first))
        val regranted = requireNotNull(rig.owner.commandAdmission())
        assertTrue(rig.owner.sendCommand(3, regranted))
        rig.owner.retry(); runCurrent(); rig.connected()
        val next = rig.clients.last()
        next.events.send(RelayClientEvent.ControlChanged(true, next.currentSource))
        assertFalse(rig.owner.sendCommand(4, regranted))
        assertTrue(rig.owner.sendCommand(5))
        assertEquals(listOf(1, 3), old.commands)
        assertEquals(listOf(5), next.commands)
        next.allowCommand = false
        assertFalse(rig.owner.sendCommand(6), "Native outbound refusal must stay a refusal")
        rig.owner.stop()
    }

    /** Payload fixtures remain in the original wire/socket tests; this port drives owner timing. */
    private class Wire : RelayControlWireCodec<Int, Int, Int, Boolean, RelayViewerRefusal> {
        override val profile: RelayWireProfile = RelayWireProfile.SHARED_MONITOR
        override fun videoDescription(metadata: Int): RelayVideoDescription = RelayVideoDescription(metadata, true, null)
        override fun holderIsRecipient(control: Boolean): Boolean = control
        override fun encodeHello(hello: RelayPeerHello): ByteArray = error("manual connection port")
        override fun decodeHello(payload: ByteArray): RelayPeerHello = error("manual connection port")
        override fun encodeState(state: Int): ByteArray = error("manual connection port")
        override fun decodeState(payload: ByteArray): Int = error("manual connection port")
        override fun encodeCommand(command: Int): ByteArray = error("manual connection port")
        override fun decodeCommand(payload: ByteArray): Int = error("manual connection port")
        override fun encodeFrame(metadata: Int, image: ByteArray): ByteArray = error("manual connection port")
        override fun decodeFrame(payload: ByteArray): RelayFramePayload<Int> = error("manual connection port")
        override fun encodeControl(holderName: String, holderIsRecipient: Boolean): ByteArray = error("manual connection port")
        override fun decodeControl(payload: ByteArray): Boolean = error("manual connection port")
        override fun encodeDenied(reason: String, passcodeRequired: Boolean): ByteArray = error("manual connection port")
        override fun decodeDenied(payload: ByteArray): RelayViewerRefusal = error("manual connection port")
    }
}
