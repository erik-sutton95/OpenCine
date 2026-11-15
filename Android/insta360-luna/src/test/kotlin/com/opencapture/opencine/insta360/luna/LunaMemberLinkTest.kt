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
import kotlinx.coroutines.test.TestScope
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

    private fun link(port: FakeLunaStationPort, conversion: (String) -> String? = { null }) = LunaMemberLink(port, { now }, conversion)

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

    @Test
    fun aStallRestartsLiveInPlace() = runTest {
        // Android's live link runs the stall ladder itself: the link only waits, never Bluetooth.
        val port = FakeLunaStationPort(backgroundScope)
        val link = live(port)
        port.secondsSinceVideo = 7.0
        assertEquals(MultiviewRepairStep.Handled, link.repair(MultiviewRepairContext()))
        assertTrue(port.steps.none { it is FakeLunaStationPort.Step.Authorize })
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
        val link = link(port) { if (it == "I-Log") "I-Log to Rec.709" else null }
        assertEquals(MultiviewAutoLUT(null, null), link.autoLUT)
        link.open(sighting, "192.168.1.31", lunaA, studio)
        port.camera.colorMode = 2
        port.camera.reportSettings()
        assertEquals("I-Log", link.autoLUT.colorMode)
        assertEquals("I-Log to Rec.709", link.autoLUT.conversion)
    }
}
