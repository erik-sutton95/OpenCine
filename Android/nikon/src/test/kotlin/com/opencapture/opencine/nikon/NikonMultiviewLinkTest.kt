package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.MulticamQualification
import com.opencapture.opencine.core.MulticamQualificationRefusal
import com.opencapture.opencine.core.MultiviewAutoLUT
import com.opencapture.opencine.core.MultiviewLinkStatus
import com.opencapture.opencine.core.MultiviewRepairContext
import com.opencapture.opencine.core.MultiviewRepairResult
import com.opencapture.opencine.core.MultiviewRepairStep
import com.opencapture.opencine.core.PictureHealth
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.StationNetwork
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlin.test.fail
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * Shared Multiview (Plan 6): the Nikon Add list, its scanner and the member link the shared
 * coordinator drives. Scripted bodies and virtual time; physical Nikon behavior is untested. Swift
 * mirror: `NikonMultiviewLinkTests`, same method names.
 */
class NikonMultiviewLinkTest {
    private class Down : Exception()

    // Add list and scanner

    @Test
    fun theAddListMergesSightingsAndSavedSetupsByHost() {
        val sightings = listOf(
            NikonSighting("192.168.1.20", "Z 8", NikonSighting.Source.NETWORK),
            NikonSighting("192.168.1.21", null, NikonSighting.Source.LIVENESS),
            NikonSighting("192.168.1.22", null, NikonSighting.Source.HELD_BY_ANOTHER_DEVICE, heldBy = "iPad"),
            NikonSighting("usb:7", "Z 6III", NikonSighting.Source.USB),
        )
        val saved = listOf(
            NikonMultiviewSavedSetup(" 192.168.1.21 ", "ZR studio"),
            NikonMultiviewSavedSetup("192.168.1.23", "Z f"),
            NikonMultiviewSavedSetup("ap:Z_123", "Access point"),
            NikonMultiviewSavedSetup("usb:7", "Cable"),
        )
        val list = NikonMultiview.addList(sightings, saved, excludedHosts = setOf("192.168.1.20 "))
        assertEquals(listOf("192.168.1.21", "192.168.1.22", "192.168.1.23"), list.map { it.host }, "a member's host is never listed")
        assertEquals(listOf("ZR studio", "Camera 192.168.1.22", "Z f"), list.map { it.name }, "a saved setup names its host's row")
        assertTrue(list[1].heldByAnotherDevice && list[1].holder == "iPad")
        val policy = NikonMultiview.policy
        assertFalse(policy.discoversByProbe, "bodies are never probed")
        assertEquals(MulticamQualification.Qualified, policy.qualification(list[0], experimental = false))
        assertEquals(
            MulticamQualification.Refused(MulticamQualificationRefusal.NOT_REACHABLE),
            policy.qualification(list[1], experimental = false),
        )
        assertEquals("192.168.1.21", policy.hostKey(" 192.168.1.21"))
        assertEquals(NikonMultiviewCamera("192.168.1.21 ", "Other").id, list[0].id, "one id per host")
        assertNotEquals(list[2].id, list[0].id)
        assertEquals(list[0].id, list[0].record.id)
    }

    @Test
    fun theScannerReportsEachPassAndNeverAsksAMembersHost() = runTest {
        val asked = mutableListOf<Pair<List<String>, Set<String>>>()
        val scanner = NikonMultiviewScanner(
            sightings = { saved, excluded ->
                asked += saved to excluded
                listOf(NikonSighting("192.168.1.20", "Z 8", NikonSighting.Source.NETWORK))
            },
            saved = {
                listOf(NikonMultiviewSavedSetup("192.168.1.21", "ZR"), NikonMultiviewSavedSetup("192.168.1.23", "Member"))
            },
            excludedHosts = { setOf("192.168.1.23") },
        )
        assertTrue(scanner.waitUntilReady())
        val found = mutableListOf<String>()
        val scan = launch { scanner.scan { found += it.host } }
        runCurrent()
        assertEquals(listOf("192.168.1.21"), asked.first().first, "a member's saved host is not dialled for liveness")
        assertEquals(setOf("192.168.1.23"), asked.first().second)
        advanceTimeBy(3.seconds)
        runCurrent()
        assertEquals(listOf("192.168.1.20", "192.168.1.21", "192.168.1.20", "192.168.1.21"), found)
        scanner.stop()
        advanceTimeBy(3.seconds)
        runCurrent()
        scan.join()
        assertEquals(2, asked.size, "no pass after stop")
    }

    // Member link

    /** One scripted Z body on its own PTP session. */
    private class Body(override val serialNumber: String) : NikonMultiviewTransport {
        val log = mutableListOf<String>()
        private val pending = Channel<LiveFrame>(Channel.UNLIMITED)
        val properties = MutableStateFlow(CameraPropertySnapshot())
        override val session: BodySession = BodySession(this)

        override val frames: Flow<LiveFrame> = flow {
            log += "startLiveView"
            try {
                for (frame in pending) emit(frame)
            } finally {
                log += "stopLiveView"
            }
        }

        /** The next frame the body sends. */
        fun frame(recording: Boolean = false) {
            session.reportedRecordingFlow.value = recording
            pending.trySend(
                LiveFrame(
                    timestampNanos = 0,
                    jpegData = byteArrayOf(-1, -40),
                    isRecording = recording,
                    timecode = LiveFrameTimecode(on = true, hour = 1, minute = 2, second = 3, frame = 4),
                ),
            )
        }

        override suspend fun shutdown() {
            log += "shutdown"
        }
    }

    /** The body's control session: the Swift core reports what the frame header says. */
    private class BodySession(private val body: Body) : CameraSession {
        override val state: StateFlow<CameraSessionState> =
            MutableStateFlow(CameraSessionState.Connected(CameraIdentity("ZR", "ZR", body.serialNumber.trim())))
        override val recordingState: StateFlow<CameraRecordingState> = MutableStateFlow(CameraRecordingState.STANDBY)
        val reportedRecordingFlow = MutableStateFlow<Boolean?>(null)
        override val reportedRecording: StateFlow<Boolean?> = reportedRecordingFlow
        override val cameraProperties: StateFlow<CameraPropertySnapshot> get() = body.properties

        override suspend fun connect() {}

        override suspend fun setRecording(recording: Boolean) {
            body.log += if (recording) "record start" else "record stop"
        }

        override suspend fun disconnect() {}
    }

    /** The bodies on the network, the devices holding some, every dial, and a stage's opener and links. */
    private class Rig(val test: TestScope) {
        val bodies = mutableMapOf<String, Body>()
        val holders = mutableMapOf<String, String>()
        val connects = mutableListOf<String>()
        var connectGate: CompletableDeferred<Unit>? = null
        var gateWaiting = 0
        val statuses = mutableListOf<MultiviewLinkStatus>()
        var frames = 0
        val now: () -> MonotonicInstant = { MonotonicInstant(test.testScheduler.currentTime.milliseconds) }

        val opener = NikonMemberOpener<Body>(
            now = now,
            sleep = { delay(it) },
            currentHolder = { holders[it] },
            connect = { host ->
                connects += host
                connectGate?.let { gate ->
                    gateWaiting += 1
                    // The dial itself does not stop for a cancelled repair: the link must close it.
                    withContext(NonCancellable) { gate.await() }
                }
                bodies[host] ?: throw Down()
            },
            serialNumber = { it.serialNumber },
            close = { it.shutdown() },
        )

        fun link(): NikonMultiviewLink<Body> {
            val link = NikonMultiviewLink(
                opener = opener,
                scope = test.backgroundScope,
                conversion = { if (it == NikonMovieTone.N_LOG) "N-Log look" else null },
                now = now,
                wallClock = { test.testScheduler.currentTime },
                frameDeadline = FRAME_DEADLINE,
            )
            link.onStatus = { statuses += it }
            link.onFrame = { frames += 1 }
            return link
        }

        /** A link live on the body at 192.168.1.20 (serial 3001), one frame shown. */
        suspend fun live(body: Body = Body("3001")): NikonMultiviewLink<Body> {
            bodies["192.168.1.20"] = body
            val link = link()
            val camera = NikonMultiviewCamera("192.168.1.20", "ZR")
            link.open(camera, "192.168.1.20", expecting = null, network = NETWORK)
            link.startPreview(camera)
            body.frame()
            until { link.pictureHealth == PictureHealth.LIVE }
            return link
        }

        /** Three frame deadlines pass without a picture: the pump stops on a stall. */
        suspend fun stall(link: NikonMultiviewLink<Body>) {
            repeat(NikonMemberRepair.MISSED_FRAMES_FOR_STALL) {
                test.advanceTimeBy(FRAME_DEADLINE)
                test.runCurrent()
            }
            until { link.pictureHealth == PictureHealth.STALLED }
        }

        suspend fun until(condition: () -> Boolean) {
            repeat(1_000) {
                if (condition()) return
                test.runCurrent()
                yield()
            }
            fail("condition never held")
        }

        companion object {
            val NETWORK = StationNetwork(ssid = "", password = "", hotspot = false)
            val FRAME_DEADLINE = 10.seconds
        }
    }

    /** A repair context that counts the attempts it grants. */
    private class Budget(val limit: Int) {
        var asked = 0
        val context: MultiviewRepairContext
            get() = MultiviewRepairContext(beginAttempt = {
                asked += 1
                asked <= limit
            })
    }

    @Test
    fun openingChecksTheBodyAndRefusesWithOperatorCopy() = runTest {
        val rig = Rig(this)
        rig.bodies["192.168.1.20"] = Body(" 3001 ")
        rig.holders["192.168.1.21"] = "iPad"
        val link = rig.link()
        val camera = NikonMultiviewCamera("192.168.1.20", "ZR")
        val proven = link.open(camera, "192.168.1.20", expecting = null, network = Rig.NETWORK)
        assertContentEquals("3001".toByteArray(), proven, "the serial GetDeviceInfo reported is the identity")
        assertEquals(listOf(MultiviewLinkStatus.OPENING), rig.statuses)
        assertEquals(CameraDeviceID.durable("3001", NikonOpenCineSession.INTEGRATION), link.snapshot.device)

        val reopened = async {
            runCatching { link.open(camera, "192.168.1.20", expecting = "9999".toByteArray(), network = Rig.NETWORK) }
        }
        runCurrent() // the host's settle after the close
        assertEquals(1, rig.connects.size, "no Init inside the settle")
        advanceTimeBy(1_200.milliseconds)
        runCurrent()
        assertEquals(
            NikonMultiviewLinkError.Refused(NikonMemberOpenRefusal.DIFFERENT_BODY, null),
            reopened.await().exceptionOrNull(),
        )

        val held = NikonMultiviewCamera("192.168.1.21", "Z 8")
        val refused = runCatching { link.open(held, "192.168.1.21", expecting = null, network = Rig.NETWORK) }
        val error = assertIs<NikonMultiviewLinkError>(refused.exceptionOrNull(), "a held body opened")
        assertEquals("In use on iPad. Release it there, then tap Reconnect.", error.message)
        assertFalse("192.168.1.21" in rig.connects, "a body another device holds is never dialled")
        assertFalse(link.probe("192.168.1.22", Rig.NETWORK))
    }

    @Test
    fun thePumpPublishesFramesRecordStateAndTheToneLUT() = runTest {
        val rig = Rig(this)
        val body = Body("3001")
        val link = rig.live(body)
        assertEquals(
            listOf(
                MultiviewLinkStatus.OPENING,
                MultiviewLinkStatus.CONTROLLING,
                MultiviewLinkStatus.AWAITING_PICTURE,
                MultiviewLinkStatus.LIVE,
            ),
            rig.statuses,
        )
        assertEquals(1, rig.frames)
        assertEquals(false, link.recordReport?.recording)
        assertEquals(LiveFrameTimecode(on = true, hour = 1, minute = 2, second = 3, frame = 4), link.timecode)
        body.properties.value = CameraPropertySnapshot(batteryPercent = 80, movieTone = "N-Log")
        body.frame()
        rig.until { link.recordingTone != null }
        assertEquals(MultiviewAutoLUT(colorMode = "N-Log", conversion = "N-Log look"), link.autoLUT)
        assertEquals(80, link.reported.batteryPercent)
        body.frame(recording = true)
        rig.until { link.recordReport?.recording == true }
        rig.until { link.snapshot.recording.value == RecordingState.RECORDING }
        link.close()
    }

    /**
     * On Android the safe point between two frames is the Swift core's (its pump and the session's
     * command mutex share one PTP session); the link's part is that a record goes out only on the
     * member's own session, and none while Live View holds the link.
     */
    @Test
    fun queuedWritesAndRecordGoOutOnlyAtTheSafePoint() = runTest {
        val rig = Rig(this)
        val body = Body("3001")
        val link = rig.live(body)
        val lent = assertIs<NikonOpenCineSession>(link.session)
        link.lend()
        val refused = lent.request(CameraCommandIntent.StartRecording)
        assertIs<CommandStage.Rejected>(refused.stage, "Live View holds the link: nothing is sent")
        assertFalse("record start" in body.log)
        link.reclaim(body)
        val control = assertIs<NikonOpenCineSession>(link.session)
        backgroundScope.launch { control.request(CameraCommandIntent.StartRecording) }
        rig.until { "record start" in body.log }
        link.close()
    }

    @Test
    fun threeMissedFramesRestartLiveViewInPlace() = runTest {
        val rig = Rig(this)
        val body = Body("3001")
        val link = rig.live(body)
        rig.stall(link)
        assertEquals(MultiviewLinkStatus.RECONNECTING, rig.statuses.last())
        val budget = Budget(2)
        val step = assertIs<MultiviewRepairStep.Repair>(link.repair(budget.context), "a stall repairs")
        assertEquals(MultiviewRepairResult.Done, step.run())
        assertEquals(1, budget.asked, "one attempt from the coordinator's budget")
        rig.until { body.log.count { it == "startLiveView" } == 2 }
        assertEquals(1, rig.connects.size, "restarted in place: no Init")
        body.frame()
        rig.until { link.pictureHealth == PictureHealth.LIVE }
        assertEquals(MultiviewRepairStep.Healthy, link.repair(budget.context), "a picture ends the episode")
        link.close()
    }

    @Test
    fun aLostLinkReopensTheSameBodyAfterTheSettle() = runTest {
        val rig = Rig(this)
        val body = Body("3001")
        val link = rig.live(body)
        val first = link.session.id
        link.lend()
        link.reclaim(null) // Live View lost the session
        val budget = Budget(2)
        assertEquals(MultiviewRepairStep.Handled, link.repair(budget.context), "the ladder waits out the settle")
        assertEquals(0, budget.asked, "a wait spends nothing")
        advanceTimeBy(1_200.milliseconds)
        runCurrent()
        val work = assertIs<MultiviewRepairStep.Repair>(link.repair(budget.context), "a lost link reopens")
        val reopening = async { work.run() }
        rig.until { rig.connects.size == 2 }
        assertEquals(MultiviewRepairResult.Done, reopening.await())
        assertNotEquals(first, link.session.id, "a reopened link is a new session")
        assertEquals("192.168.1.20", link.host)
        body.frame()
        rig.until { link.pictureHealth == PictureHealth.LIVE }

        rig.bodies["192.168.1.20"] = Body("4002")
        link.lend()
        link.reclaim(null)
        advanceTimeBy(1_200.milliseconds)
        runCurrent()
        val other = assertIs<MultiviewRepairStep.Repair>(link.repair(budget.context), "a lost link reopens")
        assertEquals(MultiviewRepairResult.Done, other.run())
        assertNull(link.transport, "another body at the address is refused")
        link.close()
    }

    @Test
    fun aSpentBudgetOrATakeOverWaitsForTheOperator() = runTest {
        val rig = Rig(this)
        val body = Body("3001")
        val link = rig.live(body)
        rig.stall(link)
        assertEquals(NikonMultiviewCopy.COULD_NOT_RESTORE, verdict(link.repair(Budget(0).context)))

        val taken = rig.live(Body("3002"))
        taken.lend()
        taken.reclaim(null)
        rig.holders["192.168.1.20"] = "iPad"
        advanceTimeBy(1_200.milliseconds)
        runCurrent()
        val budget = Budget(3)
        val work = assertIs<MultiviewRepairStep.Repair>(taken.repair(budget.context), "a lost link reopens")
        assertEquals(MultiviewRepairResult.Done, work.run())
        assertEquals("In use on iPad. Release it there, then tap Reconnect.", verdict(taken.repair(budget.context)))
        assertEquals(1, budget.asked, "a take-over spends no further attempt")
        link.close()
        taken.close()
    }

    @Test
    fun aReopenThatReturnsAfterTheRepairWasGivenUpIsClosed() = runTest {
        val rig = Rig(this)
        val body = Body("3001")
        val link = rig.live(body)
        link.lend()
        link.reclaim(null)
        advanceTimeBy(1_200.milliseconds)
        runCurrent()
        val gate = CompletableDeferred<Unit>()
        rig.connectGate = gate
        val work = assertIs<MultiviewRepairStep.Repair>(link.repair(Budget(2).context), "a lost link reopens")
        val repair = launch { work.run() }
        rig.until { rig.gateWaiting == 1 }
        repair.cancel() // the coordinator's repair deadline gave up on it
        gate.complete(Unit)
        repair.join()
        rig.until { body.log.count { it == "shutdown" } == 1 }
        assertNull(link.transport, "the late link is not attached")
    }

    @Test
    fun closeEndsTheSessionWithoutARecordCommandAndTheNextOpenWaitsForIt() = runTest {
        val rig = Rig(this)
        val body = Body("3001")
        val link = rig.live(body)
        link.close()
        assertNull(link.recordReport)
        rig.until { "shutdown" in body.log }
        assertFalse(body.log.any { it.startsWith("record") }, "closing never stops a recording")
        assertEquals(listOf("stopLiveView", "shutdown"), body.log.takeLast(2))
        val camera = NikonMultiviewCamera("192.168.1.20", "ZR")
        val again = async { link.open(camera, "192.168.1.20", expecting = null, network = Rig.NETWORK) }
        runCurrent()
        assertEquals(1, rig.connects.size, "the settle after the close comes first")
        advanceTimeBy(1_200.milliseconds)
        runCurrent()
        again.await()
        assertEquals(2, rig.connects.size)
        link.close()
    }

    @Test
    fun theLiveViewLoanStopsThePumpAndAReplacementIsANewSession() = runTest {
        val rig = Rig(this)
        val body = Body("3001")
        val link = rig.live(body)
        val first = link.session.id
        assertSame(body, link.lend())
        assertNull(link.lend(), "one loan at a time")
        assertEquals("healthy", verdict(link.repair(Budget(2).context)), "Live View owns the link meanwhile")
        link.reclaim(body)
        rig.until { body.log.count { it == "startLiveView" } == 2 }
        assertEquals(first, link.session.id, "the same session comes back")
        body.frame()
        rig.until { rig.frames == 2 }

        val replacement = Body("3001")
        link.lend()
        link.reclaim(replacement)
        assertNotEquals(first, link.session.id, "a replacement from Live View is a new session")
        rig.until { "startLiveView" in replacement.log }
        link.close()
    }
}

/** A repair verdict as text: its case, or the operator copy it waits with. */
private fun verdict(step: MultiviewRepairStep): String = when (step) {
    MultiviewRepairStep.Healthy -> "healthy"
    MultiviewRepairStep.Handled -> "handled"
    is MultiviewRepairStep.Repair -> "repair"
    is MultiviewRepairStep.WaitForOperator -> step.message
}
