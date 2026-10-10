package com.opencapture.opencine.watchruntime

import com.opencapture.opencine.relay.RelayPreviewPacingPolicy
import com.opencapture.opencine.relay.RelayPreviewProfile
import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** SIMULATED transport and native ports, driven by actual common owners and a manual clock. */
@OptIn(ExperimentalCoroutinesApi::class)
class WatchRuntimeOwnerTest {
    private val codec = Codec()
    private val connected = State(WatchRelayConnection.CONNECTED, feedLive = true)

    @Test fun receiverAcknowledgesBeforeDecodeAndOldFramesCannotEnterReplacementSource() {
        val clock = Clock()
        val port = Port()
        var decoded = 0
        val owner = receiver(clock, port) { image ->
            assertTrue(port.sent.last().path.startsWith("/frame-ack/"))
            decoded += 1
            image.single().toInt()
        }
        connect(owner)
        val source = owner.source
        val revision = owner.snapshot.value.presentationRevision
        owner.receive("phone", "/frame/2", codec.encodeFrame(Frame(2)), source)
        owner.receive("phone", "/frame/1", codec.encodeFrame(Frame(1)), source)
        owner.receive("phone", "/frame/2", codec.encodeFrame(Frame(2)), source)
        assertEquals(3, port.sent.count { it.path.startsWith("/frame-ack/") })
        assertEquals(1, decoded)
        assertEquals(2, owner.snapshot.value.image)
        assertEquals(2, owner.snapshot.value.timecode)

        owner.stop()
        connect(owner)
        assertTrue(owner.snapshot.value.presentationRevision > revision)
        assertTrue(owner.source != source)
        val before = port.sent.size
        owner.receive("phone", "/frame/3", codec.encodeFrame(Frame(3)), source)
        assertEquals(before, port.sent.size)
        assertNull(owner.snapshot.value.image)
        owner.receive("phone", "/frame/1", codec.encodeFrame(Frame(1)), owner.source)
        assertEquals(1, owner.snapshot.value.image)
    }

    @Test fun receiverResultRequiresRequestPeerSourceAndExpiredCommandsCannotClearSuccessor() {
        val clock = Clock(now = 100)
        val port = Port()
        val owner = receiver(clock, port)
        connect(owner)
        assertTrue(owner.sendToggleRecord())
        val first = port.sent.last()
        val oldSource = owner.source
        owner.receive("other", "/result/1", codec.encodeResult(Result(true, true)), oldSource)
        owner.receive("phone", "/result/2", codec.encodeResult(Result(true, true)), oldSource)
        owner.receive("phone", "/result/1", byteArrayOf(99), oldSource)
        assertTrue(owner.snapshot.value.isSendingCommand)
        clock.advance(5_000)
        assertFalse(owner.snapshot.value.isSendingCommand)
        assertEquals("timeout", owner.snapshot.value.commandMessage)
        assertTrue(owner.sendToggleRecord())
        first.failure?.invoke()
        owner.receive("phone", "/result/1", codec.encodeResult(Result(true, true)), oldSource)
        assertTrue(owner.snapshot.value.isSendingCommand)
        owner.receive("phone", "/result/2", codec.encodeResult(Result(true, true)), owner.source)
        assertFalse(owner.snapshot.value.isSendingCommand)
        assertTrue(assertNotNull(owner.snapshot.value.state).recording)

        clock.advance(999)
        assertNotNull(owner.snapshot.value.state)
        clock.advance(1)
        assertNull(owner.snapshot.value.state)
        assertTrue(owner.snapshot.value.phoneReachable)
        assertFalse(owner.sendToggleRecord())
        owner.close()
        val afterClose = port.sent.size
        first.failure?.invoke()
        clock.deliverCanceled()
        assertEquals(afterClose, port.sent.size)
        assertFalse(owner.start())
    }

    @Test fun receiverRetiresActualPeerAbaAndRejectsMalformedOrUnreachableState() {
        val clock = Clock()
        val port = Port()
        val owner = receiver(clock, port)
        connect(owner)
        assertTrue(owner.sendToggleRecord())
        val source = owner.source
        val revision = owner.snapshot.value.presentationRevision
        owner.acceptNodes(emptySet(), source)
        owner.acceptNodes(setOf("phone"), owner.source)
        assertTrue(owner.snapshot.value.presentationRevision > revision)
        owner.receive("phone", "/state", codec.encodeState(connected), source)
        owner.receive("other", "/state", codec.encodeState(connected), owner.source)
        owner.receive("phone", "/state", byteArrayOf(1), owner.source)
        owner.receive("phone", "/frame/-1", codec.encodeFrame(Frame(1)), owner.source)
        assertNull(owner.snapshot.value.state)
        assertFalse(owner.snapshot.value.isSendingCommand)
        assertFalse(owner.sendToggleRecord())
        assertEquals(1, port.sent.size)
    }

    @Test fun phoneLatestPreviewOldEncodeAndDuplicateAckCannotReleaseSuccessorCapacity() = runTest {
        val clock = Clock()
        val port = Port()
        val releases = mutableMapOf<Int, CompletableDeferred<Unit>>()
        val entered = mutableListOf<Int>()
        val discarded = mutableListOf<Int>()
        val owner = WatchPhoneOwner(backgroundScope, codec, clock, port, phonePolicy(maximumInFlight = 1),
            encode = { value: Int, _ ->
                entered += value
                releases.getOrPut(value) { CompletableDeferred() }.await()
                Frame(value)
            }, discard = discarded::add)
        connect(owner)
        val oldSource = owner.source
        owner.ingestPreview(1, oldSource)
        runCurrent()
        owner.ingestPreview(2, oldSource)
        owner.ingestPreview(3, oldSource)
        assertEquals(listOf(2), discarded)
        owner.retireSource(clearState = true)
        assertEquals(listOf(2, 3), discarded)
        owner.publishState(connected)
        val current = owner.source
        owner.ingestPreview(4, current)
        runCurrent()
        owner.ingestPreview(5, current)
        releases.getValue(1).complete(Unit)
        runCurrent()
        assertEquals(listOf(1, 4), entered)
        assertTrue(port.sent.none { it.path.startsWith("/frame/") })
        releases.getValue(4).complete(Unit)
        runCurrent()
        val frame = port.sent.single { it.path.startsWith("/frame/") }
        val token = assertNotNull(codec.paths.requestID(frame.path, "/frame"))
        owner.receive("other", "/frame-ack/$token", ByteArray(0), current)
        runCurrent()
        assertEquals(listOf(1, 4), entered)
        owner.receive("watch", "/frame-ack/$token", ByteArray(0), current)
        runCurrent()
        assertEquals(listOf(1, 4, 5), entered)
        owner.ingestPreview(6, current)
        owner.receive("watch", "/frame-ack/$token", ByteArray(0), current)
        runCurrent()
        assertEquals(listOf(1, 4, 5), entered)
        owner.close()
        releases.getValue(5).complete(Unit)
        runCurrent()
        assertEquals(1, port.sent.count { it.path.startsWith("/frame/") })
        assertEquals(setOf(1, 2, 3, 4, 5, 6), discarded.toSet())
    }

    @Test fun phoneFailedEncoderReleasesOneReservationAndAckTimeoutDegradesActualBudget() = runTest {
        val clock = Clock()
        val port = Port()
        val entered = mutableListOf<Int>()
        val owner = WatchPhoneOwner(backgroundScope, codec, clock, port, phonePolicy(maximumInFlight = 1),
            encode = { value: Int, _ ->
                entered += value
                if (value == 1) error("native encoding failed")
                Frame(value)
            })
        connect(owner)
        owner.ingestPreview(1)
        owner.ingestPreview(2)
        runCurrent()
        assertEquals(listOf(1, 2), entered)
        assertEquals(336, owner.currentProfile().maximumWidth)
        assertEquals(1, port.sent.count { it.path.startsWith("/frame/") })
        clock.advance(2_000)
        assertEquals(256, owner.currentProfile().maximumWidth)
        owner.ingestPreview(3)
        runCurrent()
        val latest = port.sent.last { it.path.startsWith("/frame/") }
        val request = assertNotNull(codec.paths.requestID(latest.path, "/frame"))
        clock.advance(90)
        owner.receive("watch", "/frame-ack/$request", ByteArray(0), owner.source)
        assertEquals(416, owner.currentProfile().maximumWidth)
        owner.close()
    }

    @Test fun phoneCommandsCaptureSourceBeforeDispatchAndOldSuspendedReplyNeverEntersNewSource() = runTest {
        val clock = Clock()
        val port = Port()
        val owner = WatchPhoneOwner(backgroundScope, codec, clock, port, phonePolicy(),
            encode = { value: Int, _ -> Frame(value) })
        val admissions = mutableListOf<WatchCommandAdmission>()
        val resume = CompletableDeferred<Unit>()
        owner.onCommand = { _, admission ->
            admissions += admission
            resume.await()
            Result(true, true)
        }
        connect(owner)
        owner.receive("watch", "/command/1", codec.encodeCommand(WatchRelayAction.TOGGLE_RECORD), owner.source)
        owner.retireSource(clearState = true)
        owner.publishState(connected)
        runCurrent()
        assertTrue(admissions.isEmpty())
        owner.receive("watch", "/command/2", codec.encodeCommand(WatchRelayAction.TOGGLE_RECORD), owner.source)
        runCurrent()
        val admission = admissions.single()
        assertTrue(owner.admits(admission))
        owner.retireSource(clearState = true)
        owner.publishState(connected)
        assertFalse(owner.admits(admission))
        resume.complete(Unit)
        runCurrent()
        assertTrue(port.sent.none { it.path.startsWith("/result/") })
        owner.close()
        val before = port.sent.size
        owner.receive("watch", "/command/3", codec.encodeCommand(WatchRelayAction.TOGGLE_RECORD), owner.source)
        clock.deliverCanceled()
        runCurrent()
        assertEquals(before, port.sent.size)
        assertEquals(1, admissions.size)
    }

    @Test fun phoneStateCoalescingFailureAndHeartbeatKeepExactCurrentSource() = runTest {
        val clock = Clock()
        val port = Port()
        val owner = WatchPhoneOwner(backgroundScope, codec, clock, port, phonePolicy(),
            encode = { value: Int, _ -> Frame(value) })
        connect(owner)
        val first = port.sent.single()
        owner.publishState(connected)
        assertEquals(1, port.sent.size)
        val recording = connected.copy(recording = true)
        owner.publishState(recording)
        first.failure?.invoke()
        owner.publishState(recording)
        assertEquals(2, port.sent.size)
        port.sent.last().failure?.invoke()
        owner.publishState(recording)
        assertEquals(3, port.sent.size)
        clock.advance(2_000)
        assertEquals(4, port.sent.size)
        val old = owner.source
        owner.deactivate()
        owner.activate()
        owner.acceptNodes(setOf("watch"), owner.source)
        val afterReconnect = port.sent.size
        owner.receive("watch", "/command/1", codec.encodeCommand(WatchRelayAction.TOGGLE_RECORD), old)
        clock.deliverCanceled()
        runCurrent()
        assertEquals(afterReconnect, port.sent.size)
        assertTrue(port.sent.none { it.path.startsWith("/result/") })
        owner.close()
    }

    @Test fun deployedRouteSuffixParserRejectsPartialSignedOverflowAndUnrelatedPaths() {
        for (path in listOf("/command", "/command/", "/command/0", "/command/-1", "/command/+1",
            "/command/1/extra", "/command/9223372036854775808", "/other/1")) {
            assertNull(codec.paths.requestID(path, "/command"))
        }
        assertEquals(42L, codec.paths.requestID("/command/42", "/command"))
    }

    @Test fun capturedCommandReceiptsRejectSourceAndReachabilityAbaBeforeUnsentNativeDispatch() = runTest {
        val clock = Clock()
        val port = Port()
        val owner = WatchPhoneOwner(backgroundScope, codec, clock, port, phonePolicy(),
            encode = { value: Int, _ -> Frame(value) })
        val admitted = mutableListOf<WatchCommandAdmission>()
        val releases = mutableListOf<CompletableDeferred<Unit>>()
        var nativeSends = 0
        owner.onCommand = { _, receipt ->
            admitted += receipt
            val release = CompletableDeferred<Unit>()
            releases += release
            release.await()
            if (owner.admits(receipt)) { nativeSends++; Result(true, true) } else Result(false, false)
        }
        connect(owner)
        val firstSource = owner.source
        owner.receive("watch", "/command/42", codec.encodeCommand(WatchRelayAction.TOGGLE_RECORD), firstSource)
        runCurrent()
        assertEquals(WatchCommandAdmission(firstSource, "watch", 42), admitted.single())
        assertTrue(owner.admits(admitted.single()))
        owner.acceptNodes(emptySet(), firstSource)
        owner.acceptNodes(setOf("watch"), owner.source)
        assertFalse(owner.admits(admitted.single()))
        releases[0].complete(Unit)
        runCurrent()
        assertEquals(0, nativeSends)
        assertTrue(port.sent.none { it.path.startsWith("/result/") })
        owner.receive("watch", "/command/43", codec.encodeCommand(WatchRelayAction.TOGGLE_RECORD), owner.source)
        runCurrent()
        assertTrue(owner.admits(admitted[1]))
        releases[1].complete(Unit)
        runCurrent()
        assertEquals(1, nativeSends)
        assertEquals("/result/43", port.sent.last().path)
        owner.retireSource(clearState = true)
        assertFalse(owner.admits(admitted[1]))
        owner.close()
        assertEquals(1, nativeSends)
    }

    @Test fun enteredNativeWorkCompletesAfterRetirementWithoutReplyingIntoReplacementSource() = runTest {
        val clock = Clock()
        val port = Port()
        val owner = WatchPhoneOwner(backgroundScope, codec, clock, port, phonePolicy(),
            encode = { value: Int, _ -> Frame(value) })
        val release = CompletableDeferred<Unit>()
        var sends = 0
        var completions = 0
        owner.onCommand = { _, receipt ->
            assertTrue(owner.admits(receipt))
            sends++
            release.await()
            completions++
            Result(true, true)
        }
        connect(owner)
        owner.receive("watch", "/command/1", codec.encodeCommand(WatchRelayAction.TOGGLE_RECORD), owner.source)
        runCurrent()
        assertEquals(1, sends)
        owner.retireSource(clearState = true)
        owner.publishState(connected)
        release.complete(Unit)
        runCurrent()
        assertEquals(1, completions)
        assertTrue(port.sent.none { it.path.startsWith("/result/") })
        owner.close()
        assertEquals(1, sends)
    }

    private fun receiver(clock: Clock, port: Port, decode: (ByteArray) -> Int? = { it.singleOrNull()?.toInt() }):
        WatchReceiverOwner<State, Frame, WatchRelayAction, Result, Int, Int> =
        WatchReceiverOwner(codec, clock, port, decode, WatchReceiverPolicy(unavailableError = "unavailable", timeoutError = "timeout"))

    private fun connect(owner: WatchReceiverOwner<State, Frame, WatchRelayAction, Result, Int, Int>) {
        owner.start()
        owner.acceptNodes(setOf("phone"), owner.source)
        owner.receive("phone", "/state", codec.encodeState(connected), owner.source)
    }
    private fun connect(owner: WatchPhoneOwner<State, Frame, WatchRelayAction, Result, Int, Int>) {
        owner.activate()
        owner.acceptNodes(setOf("watch"), owner.source)
        owner.publishState(connected)
    }
    private fun phonePolicy(maximumInFlight: Int = 3): WatchPhonePolicy = WatchPhonePolicy(
        RelayPreviewPacingPolicy(listOf(RelayPreviewProfile(416, 32), RelayPreviewProfile(336, 28), RelayPreviewProfile(256, 24)),
            listOf(0.2, 0.35), initialIndex = 1, sampleUnitsPerSecond = 1_000.0), maximumInFlight)

    private data class State(val connection: WatchRelayConnection, val feedLive: Boolean, val recording: Boolean = false)
    private data class Frame(val sequence: Int)
    private data class Result(val accepted: Boolean, val recording: Boolean, val error: String? = null)
    private class Codec : WatchRelayCodec<State, Frame, WatchRelayAction, Result, Int> {
        override val paths: WatchRelayPaths = WatchRelayPaths("/state", "/frame", "/frame-ack", "/command", "/result")
        override fun decode(data: ByteArray): WatchRelayMessage<State, Frame, WatchRelayAction, Result>? =
            when (data.firstOrNull()?.toInt()) {
                1 -> if (data.size != 4 || data[1].toInt() !in WatchRelayConnection.entries.indices) null
                    else WatchRelayMessage.State(State(WatchRelayConnection.entries[data[1].toInt()], data[2] == 1.toByte(), data[3] == 1.toByte()))
                2 -> if (data.size != 2) null else WatchRelayMessage.Frame(Frame(data[1].toInt()))
                16 -> if (data.size != 2 || data[1].toInt() !in WatchRelayAction.entries.indices) null
                    else WatchRelayMessage.Command(WatchRelayAction.entries[data[1].toInt()])
                17 -> if (data.size != 3) null else WatchRelayMessage.Result(Result(data[1] == 1.toByte(), data[2] == 1.toByte()))
                else -> null
            }
        override fun encodeState(state: State): ByteArray = byteArrayOf(1, state.connection.ordinal.toByte(),
            (if (state.feedLive) 1 else 0).toByte(), (if (state.recording) 1 else 0).toByte())
        override fun encodeFrame(frame: Frame): ByteArray = byteArrayOf(2, frame.sequence.toByte())
        override fun encodeCommand(action: WatchRelayAction): ByteArray = byteArrayOf(16, action.ordinal.toByte())
        override fun encodeResult(result: Result): ByteArray = byteArrayOf(17, (if (result.accepted) 1 else 0).toByte(),
            (if (result.recording) 1 else 0).toByte())
        override fun action(command: WatchRelayAction): WatchRelayAction = command
        override fun facts(state: State): WatchRelaySourceFacts = WatchRelaySourceFacts(state.connection, state.feedLive)
        override fun replacing(state: State, result: Result): State = state.copy(recording = result.recording)
        override fun error(result: Result): String? = result.error
        override fun result(accepted: Boolean, isRecording: Boolean, error: String?): Result = Result(accepted, isRecording, error)
        override fun image(frame: Frame): ByteArray = byteArrayOf(frame.sequence.toByte())
        override fun timecode(frame: Frame): Int = frame.sequence
        override fun stateMatches(first: State, second: State): Boolean = first == second
    }
    private class Port : WatchMessagePort {
        data class Sent(val node: String, val path: String, val bytes: ByteArray, val failure: (() -> Unit)?)
        val sent = mutableListOf<Sent>()
        override fun send(node: String, path: String, bytes: ByteArray, onFailure: (() -> Unit)?) {
            sent += Sent(node, path, bytes.copyOf(), onFailure)
        }
    }
    private class Clock(var now: Long = 0) : WatchRuntimeScheduler {
        private data class Job(val at: Long, val action: () -> Unit, var canceled: Boolean = false, var delivered: Boolean = false)
        private val jobs = mutableListOf<Job>()
        override fun nowMillis(): Long = now
        override fun schedule(afterMillis: Long, action: () -> Unit): WatchScheduled {
            val job = Job(now + afterMillis, action)
            jobs += job
            return WatchScheduled { job.canceled = true }
        }
        fun advance(millis: Long) {
            val target = now + millis
            while (true) {
                val job = jobs.filter { !it.canceled && !it.delivered && it.at <= target }.minByOrNull { it.at } ?: break
                now = job.at
                job.delivered = true
                job.action()
            }
            now = target
        }
        fun deliverCanceled() {
            jobs.toList().filter { it.canceled && !it.delivered }.forEach { it.delivered = true; it.action() }
        }
    }
}
