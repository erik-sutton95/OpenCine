package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.MultiviewAutoLUT
import com.opencapture.opencine.core.MultiviewLinkStatus
import com.opencapture.opencine.core.MultiviewRecordReport
import com.opencapture.opencine.core.MultiviewRepairContext
import com.opencapture.opencine.core.MultiviewRepairResult
import com.opencapture.opencine.core.MultiviewRepairStep
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.PictureHealth
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.StationNetwork
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * One Luna member on a Multiview stage: the probe, the LAN-only open with the serial checked, the
 * picture and record reports, Luna's repair (Bluetooth only in the coordinator's turn) and the Auto
 * LUT source. Swift mirror: `LunaMemberLinkTests`, same names.
 */
class LunaMemberLinkTest {
    private val sighting = NearbyCamera(
        id = "AA:BB:CC:DD:EE:01", name = "Luna A1B2", model = "Insta360 Luna Ultra", routes = setOf(RouteKind.CAMERA_ACCESS_POINT),
    )
    private val studio = StationNetwork("Studio", "synthetic1", false)
    private val lunaA = LunaMultiview.identity("LUNA-A")
    private var now = 0L

    private fun link(port: FakeLunaStationPort, conversion: (String) -> String? = { null }, preview: (String) -> String = { it }) =
        LunaMemberLink(port, { now }, conversion, preview)

    /** A link whose camera LUNA-A answers at 192.168.1.31, opened and previewing. */
    private suspend fun TestScope.live(port: FakeLunaStationPort): LunaMemberLink {
        port.cameras["192.168.1.31"] = "LUNA-A"
        port.answering = setOf("192.168.1.31")
        val link = link(port)
        link.open(sighting, "192.168.1.31", lunaA, studio)
        link.startPreview(sighting)
        return link
    }

    @Test
    fun openChecksTheSerialAtTheAddress() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        port.cameras["192.168.1.31"] = "LUNA-A"
        val link = link(port)
        assertContentEquals(lunaA, link.open(sighting, "192.168.1.31", lunaA, studio))
        assertTrue(FakeLunaStationPort.Step.Connect(sighting.id, "192.168.1.31", "LUNA-A") in port.steps)
        port.cameras["192.168.1.32"] = "LUNA-B"
        assertFailsWith<LunaStationStepFailure> { link.open(sighting, "192.168.1.32", lunaA, studio) }
    }

    @Test
    fun openWithoutAnIdentityIsRefused() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        port.cameras["192.168.1.31"] = "LUNA-A"
        assertFailsWith<LunaStationStepFailure> { link(port).open(sighting, "192.168.1.31", null, studio) }
        assertTrue(port.steps.none { it is FakeLunaStationPort.Step.Connect })
    }

    @Test
    fun aSilentAddressFails() = runTest {
        assertFailsWith<LunaStationStepFailure> { link(FakeLunaStationPort(backgroundScope)).open(sighting, "192.168.1.40", lunaA, studio) }
    }

    @Test
    fun anAddressAnotherConnectionHoldsIsNeverOpened() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        port.cameras["192.168.1.31"] = "LUNA-A"
        port.stationHostsInUse = { setOf("192.168.1.31") }
        assertFailsWith<LunaStationStepFailure> { link(port).open(sighting, "192.168.1.31", lunaA, studio) }
        assertTrue(port.steps.none { it is FakeLunaStationPort.Step.Connect })
    }

    @Test
    fun probeAsksThePortOnly() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        port.answering = setOf("192.168.1.31")
        val link = link(port)
        assertTrue(link.probe("192.168.1.31", studio))
        assertFalse(link.probe("192.168.1.32", studio))
        assertEquals(listOf<FakeLunaStationPort.Step>(FakeLunaStationPort.Step.Probe("192.168.1.31"), FakeLunaStationPort.Step.Probe("192.168.1.32")), port.steps.toList())
    }

    @Test
    fun startPreviewReportsControllingThenLive() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        port.cameras["192.168.1.31"] = "LUNA-A"
        val link = link(port)
        val statuses = mutableListOf<MultiviewLinkStatus>()
        link.onStatus = { statuses += it }
        link.open(sighting, "192.168.1.31", lunaA, studio)
        port.secondsSinceVideo = null
        link.startPreview(sighting)
        assertEquals(listOf(MultiviewLinkStatus.OPENING, MultiviewLinkStatus.CONTROLLING, MultiviewLinkStatus.AWAITING_PICTURE), statuses)
        assertEquals(PictureHealth.STARTING, link.pictureHealth)
        port.secondsSinceVideo = 0.1
        link.keepalive()
        assertEquals(MultiviewLinkStatus.LIVE, statuses.last())
        assertEquals(PictureHealth.LIVE, link.pictureHealth)
    }

    @Test
    fun theRecordReportFollowsTheCamera() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        val link = live(port)
        assertNull(link.recordReport)
        port.camera.captureState = 1
        port.camera.reportCapture()
        now = 1_000
        link.keepalive()
        assertEquals(MultiviewRecordReport(true, 1_000), link.recordReport)
        now = 6_000
        link.keepalive()
        // No new report: the stamp stays, so the stage sees it go stale.
        assertEquals(1_000, link.recordReport?.receivedAtMillis)
        port.camera.captureState = 0
        port.camera.reportCapture()
        link.keepalive()
        assertEquals(MultiviewRecordReport(false, 6_000), link.recordReport)
        link.close()
        assertNull(link.recordReport)
    }

    /**
     * OPENINSTACINE-IOS-S: a record start can pause the encoder (Color Recovery), and the live link
     * does not restart live mid-take before the long recording bound, so the tile does not read
     * Reconnecting before then either.
     */
    @Test
    fun aRecordingMembersStallLeavesTheTakeAlone() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        val link = live(port)
        port.camera.captureState = 1
        port.camera.reportCapture()
        port.secondsSinceVideo = 0.5
        link.keepalive()
        val statuses = mutableListOf<MultiviewLinkStatus>()
        link.onStatus = { statuses += it }
        for (silence in listOf(3.0, 7.0, 16.0, 29.0)) {
            port.secondsSinceVideo = silence
            assertEquals(MultiviewRepairStep.Handled, link.repair(MultiviewRepairContext()))
        }
        assertTrue(statuses.isEmpty(), "a recording member's stall is not a reconnect yet")
        port.secondsSinceVideo = 31.0
        assertEquals(MultiviewRepairStep.Handled, link.repair(MultiviewRepairContext()))
        assertEquals(listOf(MultiviewLinkStatus.RECONNECTING), statuses)
    }

    @Test
    fun aStallRestartsLiveInPlace() = runTest {
        // Android's live link runs the stall ladder itself: the link only waits, never Bluetooth,
        // and the tile reads Reconnecting while live restarts, then Live again (as on iOS).
        val port = FakeLunaStationPort(backgroundScope)
        val link = live(port)
        port.secondsSinceVideo = 0.5
        link.keepalive()
        val statuses = mutableListOf<MultiviewLinkStatus>()
        link.onStatus = { statuses += it }
        port.secondsSinceVideo = 3.0
        assertEquals(MultiviewRepairStep.Handled, link.repair(MultiviewRepairContext()))
        assertTrue(statuses.isEmpty(), "a keyframe wait is not a reconnect")
        port.secondsSinceVideo = 7.0
        assertEquals(MultiviewRepairStep.Handled, link.repair(MultiviewRepairContext()))
        assertEquals(MultiviewRepairStep.Handled, link.repair(MultiviewRepairContext()))
        assertEquals(listOf(MultiviewLinkStatus.RECONNECTING), statuses)
        port.secondsSinceVideo = 0.2
        link.keepalive()
        assertEquals(listOf(MultiviewLinkStatus.RECONNECTING, MultiviewLinkStatus.LIVE), statuses)
        assertEquals(PictureHealth.LIVE, link.pictureHealth)
        assertTrue(port.steps.none { it is FakeLunaStationPort.Step.Authorize })
    }

    @Test
    fun anOpenEndsWhenTheConnectionClosesBeforeItWentLive() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        port.cameras["192.168.1.31"] = "LUNA-A"
        port.connectStaysPending = true
        val link = link(port)
        val opening = async { runCatching { link.open(sighting, "192.168.1.31", lunaA, studio) } }
        runCurrent()
        assertFalse(opening.isCompleted, "the camera is still opening")
        // Another owner closed the backend (or a stray disconnect): the phase returns to IDLE.
        port.disconnect()
        runCurrent()
        assertTrue(opening.isCompleted)
        assertIs<LunaStationStepFailure>(opening.await().exceptionOrNull())
    }

    @Test
    fun aRepairCancelledInItsBluetoothTurnReleasesTheTurn() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        val link = live(port)
        port.dropLink()
        port.answering = emptySet()
        val gate = CompletableDeferred<Unit>()
        port.during = { if (it is FakeLunaStationPort.Step.Authorize) gate.await() }
        var released = false
        val step = link.repair(MultiviewRepairContext(bluetoothTurn = { { released = true } }))
        assertIs<MultiviewRepairStep.Repair>(step)
        val running = async { step.run() }
        runCurrent()
        assertTrue(port.steps.last() is FakeLunaStationPort.Step.Authorize)
        running.cancel()
        runCurrent()
        assertTrue(running.isCancelled)
        assertTrue(released, "the coordinator's Bluetooth turn is released")
        assertFalse(port.bluetoothOpen)
    }

    @Test
    fun aLostLinkThatStillAnswersRejoinsWithoutBluetooth() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        val link = live(port)
        port.dropLink()
        var turns = 0
        val step = link.repair(MultiviewRepairContext(bluetoothTurn = { turns += 1; {} }))
        assertIs<MultiviewRepairStep.Repair>(step)
        assertEquals(MultiviewRepairResult.Rejoin, step.run())
        assertEquals(0, turns)
        assertTrue(port.steps.none { it is FakeLunaStationPort.Step.Authorize })
    }

    @Test
    fun aLostLinkMovesTheCameraUnderABluetoothTurn() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        val link = live(port)
        port.dropLink()
        port.answering = emptySet()
        var held = false
        var released = false
        val step = link.repair(MultiviewRepairContext(bluetoothTurn = { held = true; { released = true } }))
        assertIs<MultiviewRepairStep.Repair>(step)
        port.during = { if (it is FakeLunaStationPort.Step.Authorize) assertTrue(held && !released) }
        assertEquals(MultiviewRepairResult.Rejoin, step.run())
        assertTrue(released)
        assertEquals(
            listOf(FakeLunaStationPort.Step.Authorize(sighting.id), FakeLunaStationPort.Step.Move(LunaStationNetwork("Studio", "synthetic1", false))),
            port.steps.takeLast(2),
        )
    }

    @Test
    fun aCameraThatRefusesThisPhoneWaitsForTheOperator() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        val link = live(port)
        port.dropLink()
        port.answering = emptySet()
        val refusal = FakeLunaStationPort.failure(ConnectionFailure.Reason.HeldElsewhere, "approval.held-elsewhere")
        port.authorizeFailure = LunaStationStepFailure(refusal)
        val step = link.repair(MultiviewRepairContext())
        assertIs<MultiviewRepairStep.Repair>(step)
        assertEquals(MultiviewRepairResult.WaitForOperator(refusal.message), step.run())
    }

    @Test
    fun aStoppedStageGetsNoBluetoothTurn() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        val link = live(port)
        port.dropLink()
        port.answering = emptySet()
        val step = link.repair(MultiviewRepairContext(bluetoothTurn = { null }))
        assertIs<MultiviewRepairStep.Repair>(step)
        assertEquals(MultiviewRepairResult.Done, step.run())
        assertTrue(port.steps.none { it is FakeLunaStationPort.Step.Authorize })
    }

    @Test
    fun aLostSharedNetworkLeavesTheRuleToTheStage() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        val link = live(port)
        port.dropLink()
        assertEquals(MultiviewRepairStep.Healthy, link.repair(MultiviewRepairContext(pathReady = false)))
    }

    @Test
    fun closeSendsNoCameraCommand() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        val link = live(port)
        link.close()
        assertEquals(FakeLunaStationPort.Step.Disconnect, port.steps.last())
        assertTrue(port.camera.sent.isEmpty())
        assertEquals(PictureHealth.FAILED, link.pictureHealth)
    }

    @Test
    fun theSessionIsOnePerMember() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        val link = live(port)
        val first = link.session.id
        link.close()
        link.open(sighting, "192.168.1.31", lunaA, studio)
        assertEquals(first, link.session.id)
        assertEquals(1, port.sessionsOpened)
    }

    @Test
    fun autoLUTFollowsTheColorProfile() = runTest {
        val port = FakeLunaStationPort(backgroundScope)
        port.cameras["192.168.1.31"] = "LUNA-A"
        val link = link(port, conversion = { if (it == "I-Log") "I-Log to Rec.709" else null })
        assertEquals(MultiviewAutoLUT(null, null), link.autoLUT)
        link.open(sighting, "192.168.1.31", lunaA, studio)
        port.camera.colorMode = 2
        port.camera.reportSettings()
        assertEquals("I-Log", link.autoLUT.colorMode)
        assertEquals("I-Log to Rec.709", link.autoLUT.conversion)
    }

    @Test
    fun autoLUTFollowsWhatThePictureCarries() = runTest {
        // Color Recovery grades the I-Log feed before it reaches the phone: the app's preview rule
        // says the picture is Standard, so no conversion runs on top of it.
        val port = FakeLunaStationPort(backgroundScope)
        port.cameras["192.168.1.31"] = "LUNA-A"
        val link = link(port, conversion = { if (it == "I-Log") "I-Log to Rec.709" else null }, preview = { if (it == "I-Log") "Standard" else it })
        link.open(sighting, "192.168.1.31", lunaA, studio)
        port.camera.colorMode = 2
        port.camera.reportSettings()
        assertEquals(MultiviewAutoLUT("Standard", null), link.autoLUT)
        assertEquals("Auto · no conversion needed", link.autoLUT.caption(enabled = true, conversionLoaded = false))
    }
}
