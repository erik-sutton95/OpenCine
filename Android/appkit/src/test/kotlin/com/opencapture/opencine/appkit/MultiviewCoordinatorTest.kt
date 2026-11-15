package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.MulticamQualification
import com.opencapture.opencine.core.MulticamQualificationRefusal
import com.opencapture.opencine.core.MultiviewCameraPolicy
import com.opencapture.opencine.core.MultiviewLinkStatus
import com.opencapture.opencine.core.MultiviewRecordReport
import com.opencapture.opencine.core.MultiviewRepairResult
import com.opencapture.opencine.core.MultiviewRepairStep
import com.opencapture.opencine.core.StationNetwork
import com.opencapture.opencine.core.StationRestoreResult
import com.opencapture.opencine.core.testing.FakeGate
import com.opencapture.opencine.core.testing.FakeMemberLink
import com.opencapture.opencine.core.testing.FakeNearbyScanner
import com.opencapture.opencine.core.testing.FakeStationCamera
import com.opencapture.opencine.core.testing.FakeStationCommissioner
import com.opencapture.opencine.core.testing.FakeStationHostPath
import com.opencapture.opencine.multicam.RecordDirection
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

/**
 * The shared Multiview coordinator against fake seams: the behaviors OpenPocketCine's session
 * pinned, now one implementation. Swift twin: `MultiviewCoordinatorTests`.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MultiviewCoordinatorTest {
    @Test
    fun restoredStagesKeepPresentationButNeverNetworkOrCameras() = runTest {
        val stage = Fixture(
            this,
            saved = MultiviewStageJournal.Stage(
                ssid = "Previous network", hotspot = true, layout = "2 × 2 grid", focusedIndex = 2,
                cameras = listOf(journalCamera(0)), pendingReset = emptyList(), returnedToCameraWiFi = true,
                fill = true,
            ),
        )
        val c = stage.coordinator
        c.start()
        assertFalse(c.networkConfigured, "every stage asks for its network")
        assertEquals("", c.ssid)
        assertFalse(c.usePhoneHotspot, "an old hotspot stage does not lock the network kind")
        assertEquals("", c.password)
        assertTrue(c.members.all { it.camera == null }, "old slots never reconnect")
        assertEquals(MultiviewStageLayout.GRID, c.presentation.layout)
        assertEquals(2, c.presentation.selected)
        assertTrue(c.presentation.fill)
        c.stop()
    }

    @Test
    fun credentialsLoadOnlyAfterAnExplicitNetworkChoice() = runTest {
        val stage = Fixture(this)
        stage.passwords["Test phone hotspot|true"] = "saved-test-password"
        val c = stage.coordinator
        c.selectNetworkSource(true)
        assertTrue(stage.lookups.isEmpty())
        c.selectNetwork("Test phone hotspot")
        assertEquals("saved-test-password", c.password)
        assertEquals(true, stage.lookups.first().second)
        c.networkConfigured = true
        c.selectNetworkSource(false)
        assertFalse(c.networkConfigured, "changing the source invalidates the confirmation")
        assertFalse(c.usePhoneHotspot)
        assertEquals("", c.ssid)
        assertEquals("", c.password)
        c.selectNetwork("Test local Wi-Fi")
        assertEquals(2, stage.lookups.size)
        assertEquals("Test local Wi-Fi" to false, stage.lookups.last())
        assertFalse(c.networkConfigured, "selecting a name still needs Connect")
        c.password = "old-test-password"
        c.selectNetwork("Unsaved test network")
        assertEquals("", c.password, "another network never keeps an unrelated password")
    }

    @Test
    fun anAssignedCameraLocksTheNetworkUntilRemoved() = runTest {
        val stage = Fixture(this)
        val c = stage.coordinator
        c.networkConfigured = true
        c.ssid = "Old hotspot"
        c.usePhoneHotspot = true
        c.members[0].camera = FakeStationCamera("Camera A")
        c.selectNetworkSource(false)
        assertTrue(c.usePhoneHotspot, "an assigned camera still owns the network")
        c.selectNetwork("Other network")
        assertEquals("Old hotspot", c.ssid)
        assertFalse(c.configureNetwork())
        assertTrue(c.remove(0))
        c.selectNetworkSource(false)
        c.selectNetwork("New local Wi-Fi")
        assertFalse(c.usePhoneHotspot)
        assertEquals("New local Wi-Fi", c.ssid)
        assertFalse(c.networkConfigured)
    }

    @Test
    fun legacyAssignedCamerasBecomeCleanupOnly() = runTest {
        val stage = Fixture(this)
        val camera = journalCamera(0)
        stage.coordinator.restoreStage(
            MultiviewStageJournal.Stage(
                ssid = "Legacy hotspot", hotspot = true, layout = "2 × 2 grid", focusedIndex = 0,
                cameras = listOf(camera), returnedToCameraWiFi = false,
            ),
        )
        assertFalse(stage.coordinator.networkConfigured)
        assertTrue(stage.coordinator.members.all { it.camera == null })
        assertEquals("", stage.journal?.ssid)
        assertEquals(emptyList(), stage.journal?.cameras)
        assertEquals(listOf(camera), stage.journal?.pendingReset)
    }

    @Test
    fun cancellingSetupKeepsPresentationPreferences() = runTest {
        val saved = MultiviewStageJournal.Stage(
            ssid = "Previous network", hotspot = true, layout = "2 × 2 grid", focusedIndex = 2,
            cameras = emptyList(), pendingReset = emptyList(), returnedToCameraWiFi = true, fill = true,
        )
        val stage = Fixture(this)
        stage.journal = saved
        stage.coordinator.restoreStage(saved)
        assertTrue(stage.coordinator.closeStage())
        assertEquals(saved, stage.journal, "a cancelled setup leaves the last preferences")
    }

    @Test
    fun cleanupOnlyRestoreDefersRadioWorkUntilClose() = runTest {
        for (ssid in listOf("", "Forgotten test network")) {
            val camera = journalCamera(0)
            val stage = Fixture(this)
            stage.coordinator.restoreStage(
                MultiviewStageJournal.Stage(
                    ssid = ssid, hotspot = false, layout = "Grid", focusedIndex = 0, cameras = emptyList(),
                    pendingReset = listOf(camera),
                ),
            )
            assertTrue(stage.commissioner.restores.isEmpty(), "entering setup never moves a camera")
            assertFalse(stage.coordinator.networkConfigured)
            assertEquals(listOf(camera.id), stage.journal?.pendingReset?.map { it.id })
            assertTrue(stage.coordinator.closeStage())
            assertEquals(listOf(camera.id), stage.commissioner.restores)
            assertNull(stage.journal)
        }
    }

    @Test
    fun closeRetriesUnfinishedCleanupOnTheNextClose() = runTest {
        val stage = Fixture(this)
        val camera = FakeStationCamera("Scan camera")
        stage.commissioner.restoreResults[camera.id] = mutableListOf(StationRestoreResult.Failed)
        assertTrue(stage.coordinator.recordStationChange(camera))
        assertEquals("", stage.journal?.ssid)
        assertEquals(emptyList(), stage.journal?.cameras)
        assertEquals(listOf(camera.id), stage.journal?.pendingReset?.map { it.id })
        assertFalse(stage.coordinator.closeStage())
        assertTrue(stage.coordinator.hasPendingCleanup)
        assertEquals(MultiviewCopy.CLOSE_CLEANUP_FAILED, stage.coordinator.error)
        assertEquals(listOf(camera.id), stage.journal?.pendingReset?.map { it.id })
        assertTrue(stage.coordinator.closeStage())
        assertEquals(listOf(camera.id, camera.id), stage.commissioner.restores)
        assertNull(stage.journal)
        assertFalse(stage.coordinator.hasPendingCleanup)
    }

    @Test
    fun aDeferredReturnShowsTheIntegrationsCopy() = runTest {
        val stage = Fixture(this)
        val camera = FakeStationCamera("Scan camera")
        val copy = "Approve this phone on the camera, then close Multiview again."
        stage.commissioner.restoreResults[camera.id] = mutableListOf(StationRestoreResult.Deferred(copy))
        stage.coordinator.recordStationChange(camera)
        assertFalse(stage.coordinator.closeStage())
        assertEquals(copy, stage.coordinator.error)
        assertTrue(stage.coordinator.closeStage())
    }

    @Test
    fun closeReusesAnUncancelledScanCleanup() = runTest {
        val stage = Fixture(this)
        val gate = FakeGate()
        stage.commissioner.restoreGate = gate
        val camera = FakeStationCamera("Scan camera")
        stage.coordinator.recordStationChange(camera)
        val saved = assertNotNull(stage.journal?.pendingReset?.first())
        val scanCleanup = async { stage.coordinator.resetStationOnce(saved) }
        runCurrent()
        assertEquals(1, gate.waiting)
        scanCleanup.cancel()
        val closing = async { stage.coordinator.closeStage() }
        runCurrent()
        assertTrue(stage.coordinator.closing)
        gate.open()
        assertTrue(closing.await())
        assertEquals(listOf(camera.id), stage.commissioner.restores, "one return per camera")
        assertNull(stage.journal)
    }

    @Test
    fun discoveryFollowsAddAndConnectDemand() = runTest {
        val needs = MultiviewCoordinator.Companion::needsDiscovery
        assertTrue(needs(true, true, true, false))
        assertFalse(needs(true, true, false, false))
        assertTrue(needs(true, false, false, true))
        assertFalse(needs(true, false, true, false))
        assertFalse(needs(false, true, true, true))

        val stage = Fixture(this)
        val c = stage.coordinator
        c.start()
        runCurrent()
        assertTrue(stage.scanner.scanning)
        val camera = FakeStationCamera("Camera A")
        stage.scanner.see(camera)
        stage.scanner.see(camera)
        assertEquals(listOf(camera), c.found, "a camera is listed once")
        c.setApplicationActive(false)
        runCurrent()
        assertFalse(stage.scanner.scanning, "an inactive app with nothing connecting stops scanning")
        c.setApplicationActive(true)
        runCurrent()
        assertTrue(stage.scanner.scanning)
        assertEquals(2, stage.scanner.starts)
        c.stop()
    }

    @Test
    fun linkStatusShowsTheTileCopyAndTheCoordinatorOwnsTheControlHost() = runTest {
        val stage = Fixture(this)
        val member = stage.coordinator.members[0]
        val link = stage.links[0]
        member.address = "192.0.2.41"
        member.failureMessage = MultiviewCopy.COULD_NOT_RESTORE
        link.onStatus?.invoke(MultiviewLinkStatus.OPENING)
        assertEquals("Connecting normal preview", member.status)
        assertNull(member.controlHost, "opening is not yet control")
        link.onStatus?.invoke(MultiviewLinkStatus.CONTROLLING)
        assertEquals("192.0.2.41", member.controlHost, "the coordinator records the address it opened")
        assertNull(member.failureMessage)
        assertTrue(stage.host.changes.contains(0 to MultiviewMemberChange.CONTROL))
        link.onStatus?.invoke(MultiviewLinkStatus.AWAITING_PICTURE)
        assertEquals("Waiting for video", member.status)
        link.onStatus?.invoke(MultiviewLinkStatus.LIVE)
        assertEquals("Live · Video mode", member.status)
        link.onStatus?.invoke(MultiviewLinkStatus.RECONNECTING)
        assertEquals("Reconnecting…", member.status)
    }

    @Test
    fun addCommissionsJoinsAndFindsTheCameraByProbe() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val camera = FakeStationCamera("Camera A")
        stage.links[0].place(camera, "192.168.1.12")
        stage.coordinator.add(camera, 0)
        val member = stage.coordinator.members[0]
        assertEquals(listOf(camera.id), stage.commissioner.connects)
        assertEquals(stage.coordinator.stationNetwork, stage.commissioner.joins.first().second)
        assertEquals(1, stage.commissioner.linksClosed, "the Bluetooth link closes before discovery")
        assertEquals(
            listOf("192.168.1.9", "192.168.1.11", "192.168.1.12", "192.168.1.13", "192.168.1.14"),
            stage.links[0].probes,
        )
        assertEquals(listOf("192.168.1.12"), stage.links[0].opens.map { it.first })
        assertContentEquals(camera.identity, stage.links[0].opens.first().second)
        assertContentEquals(camera.identity, member.identity)
        assertEquals("192.168.1.12", member.controlHost)
        assertTrue(member.publishing && member.networkVerified && !member.connecting)
        assertEquals(MultiviewCopy.WAITING_FOR_VIDEO, member.status)
        assertNull(member.failureMessage)
        assertEquals(stage.coordinator.stationNetwork, stage.savedNetworks.last())
        assertEquals(listOf("192.168.1.12"), stage.journal?.cameras?.map { it.address })
        assertContentEquals(camera.identity, stage.journal?.cameras?.first()?.identity)
        stage.coordinator.stop()
    }

    @Test
    fun discoveryTriesTheKnownAddressFirstThenTwoPassesWithoutOtherMembers() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val c = stage.coordinator
        val camera = FakeStationCamera("Camera A")
        c.members[1].camera = FakeStationCamera("Camera B")
        c.members[1].controlHost = "192.168.1.11"
        c.members[0].camera = camera
        c.members[0].identity = camera.identity
        c.members[0].address = "192.168.1.13"
        val reconnecting = launch { c.connectPreview(0) }
        runCurrent() // the first pass ends in the 3 s pause between passes
        stage.links[0].place(camera, "192.168.1.14")
        advanceTimeBy(3.seconds)
        runCurrent()
        reconnecting.join()
        val pass = listOf("192.168.1.9", "192.168.1.12", "192.168.1.13", "192.168.1.14")
        assertEquals("192.168.1.13", stage.links[0].opens.first().first, "the known address first")
        assertEquals(pass + pass, stage.links[0].probes, "two passes without this phone or other members")
        assertEquals("192.168.1.14", c.members[0].controlHost)
        c.stop()
    }

    @Test
    fun aStageOnThePhonesHotspotWatchesTheHotspot() = runTest {
        val stage = Fixture(this, commissioner = false, discoversByProbe = false, networkPath = MultiviewNetworkPath.EITHER)
        stage.path.addresses.clear()
        stage.path.netmasks.clear()
        stage.path.addresses[true] = "172.20.10.1"
        stage.path.netmasks[true] = "255.255.255.240"
        val c = stage.coordinator
        c.screenAppeared(startsSession = true)
        val camera = FakeStationCamera("Body A", sightedAt = "172.20.10.2")
        stage.links[0].place(camera, "172.20.10.2")
        c.add(camera, 0)
        val member = c.members[0]
        assertTrue(member.publishing)
        stage.tick()
        assertEquals(1, stage.links[0].repairTicks)
        assertTrue(c.ready, "this phone is on its own hotspot")
        assertTrue(c.usePhoneHotspot)
        stage.tick(46.seconds)
        assertNull(member.failureMessage, "the hotspot is the stage's network, not a lost one")
        assertFalse(member.budget.exhausted)
        c.stop()
    }

    @Test
    fun aProbingStageOnThePhonesHotspotSearchesTheHotspotSubnet() = runTest {
        val stage = Fixture(this, commissioner = false, networkPath = MultiviewNetworkPath.EITHER)
        stage.path.addresses.clear()
        stage.path.netmasks.clear()
        stage.path.addresses[true] = "172.20.10.1"
        stage.path.netmasks[true] = "255.255.255.248"
        val c = stage.coordinator
        c.screenAppeared(startsSession = true)
        val camera = FakeStationCamera("Body A")
        stage.links[0].place(camera, "172.20.10.3")
        c.add(camera, 0)
        assertNull(c.members[0].failureMessage, "not an unsupported subnet")
        assertEquals("172.20.10.3", c.members[0].controlHost)
        c.stop()
    }

    @Test
    fun anUnsupportedSubnetFailsTheAddWithItsCopy() = runTest {
        val stage = Fixture(this, netmask = "255.255.0.0")
        stage.configure()
        stage.coordinator.add(FakeStationCamera("Camera A"), 0)
        assertEquals(MultiviewCopy.UNSUPPORTED_SUBNET, stage.coordinator.members[0].failureMessage)
        assertEquals(MultiviewCopy.COULD_NOT_CONNECT, stage.coordinator.members[0].status)
        stage.coordinator.stop()
    }

    @Test
    fun theDuplicateRefusalIsFinal() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val c = stage.coordinator
        val camera = FakeStationCamera("Camera A")
        c.members[1].camera = FakeStationCamera("Camera B")
        c.members[1].identity = camera.identity // the same body, already a member
        stage.links[0].place(camera, "192.168.1.12")
        c.add(camera, 0)
        assertEquals(MultiviewCopy.DUPLICATE, c.members[0].failureMessage)
        assertEquals(listOf("192.168.1.12"), stage.links[0].opens.map { it.first }, "the search stops there")
        c.reconnect(0)
        assertEquals(MultiviewCopy.DUPLICATE, c.members[0].failureMessage)
        c.stop()
    }

    @Test
    fun aCameraWithoutPreviewStopsAtTheVerifiedJoin() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val camera = FakeStationCamera("NoPreview camera")
        stage.links[0].place(camera, "192.168.1.12")
        stage.coordinator.add(camera, 0)
        val member = stage.coordinator.members[0]
        assertEquals(MultiviewCopy.VERIFIED_WITHOUT_PREVIEW, member.status)
        assertTrue(member.networkVerified && !member.publishing && member.failureMessage == null)
        assertEquals(0, stage.links[0].starts, "no picture is asked for")
        stage.coordinator.stop()
    }

    @Test
    fun reconnectTriesTheKnownCameraThenSetsItUpAgain() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val c = stage.coordinator
        val camera = FakeStationCamera("Camera A")
        stage.links[0].place(camera, "192.168.1.12")
        c.add(camera, 0)
        stage.links[0].answering.clear() // the camera left the network
        val gate = FakeGate()
        stage.commissioner.connectGate = gate
        val reconnecting = launch { c.reconnect(0) }
        runCurrent()
        advanceTimeBy(3.seconds)
        runCurrent()
        assertEquals(1, gate.waiting)
        assertEquals(2, stage.commissioner.connects.size, "a failed search sets the camera up again")
        stage.links[0].place(camera, "192.168.1.13")
        gate.open()
        reconnecting.join()
        assertEquals("192.168.1.13", c.members[0].controlHost)
        assertNull(c.members[0].failureMessage)
        assertEquals(camera, c.members[0].camera)
        c.stop()
    }

    @Test
    fun repairsRejoinWithinTheBudgetThenWaitForTheOperator() = runTest {
        val stage = Fixture(this)
        val (c, link, member) = stage.liveMember()
        link.repairStep = { MultiviewRepairStep.Repair { MultiviewRepairResult.Rejoin } }
        for (rejoin in 1..2) {
            stage.tick()
            assertEquals(1 + rejoin, link.opens.size)
            assertFalse(member.recovering)
            assertTrue(member.publishing, "rejoin $rejoin reopened the member")
        }
        stage.tick()
        assertEquals(MultiviewCopy.COULD_NOT_RESTORE, member.failureMessage)
        assertTrue(member.budget.exhausted)
        val ticks = link.repairTicks
        stage.tick()
        assertEquals(ticks, link.repairTicks, "an exhausted member waits for the operator")
        link.repairStep = { MultiviewRepairStep.Healthy }
        c.reconnect(0)
        assertTrue(member.failureMessage == null && member.publishing && !member.budget.exhausted)
        c.stop()
    }

    @Test
    fun aHealthyTransportRestoresTheBudget() = runTest {
        val stage = Fixture(this)
        val (c, link, member) = stage.liveMember()
        link.repairStep = { MultiviewRepairStep.Repair { MultiviewRepairResult.Rejoin } }
        stage.tick()
        assertEquals(2, link.opens.size)
        assertEquals(1, member.budget.used)
        link.repairStep = { context ->
            context.observeHealth(true)
            MultiviewRepairStep.Healthy
        }
        stage.tick()
        assertEquals(2, link.repairTicks)
        stage.tick(31.seconds) // one healthy repair tick a second
        assertEquals(33, link.repairTicks)
        assertEquals(0, member.budget.used, "30 s of a healthy transport restores the budget")
        c.stop()
    }

    @Test
    fun sharedNetworkLossFailsTheMemberAfter45Seconds() = runTest {
        val stage = Fixture(this)
        val (c, link, member) = stage.liveMember()
        stage.path.addresses[false] = null
        stage.tick()
        assertEquals(1, link.repairTicks)
        stage.tick(45.seconds) // one repair tick a second
        assertEquals(46, link.repairTicks)
        assertNull(member.failureMessage, "45 s is still within the allowance")
        stage.tick()
        assertEquals(47, link.repairTicks)
        assertEquals(MultiviewCopy.SHARED_NETWORK_LOST, member.failureMessage)
        assertTrue(member.budget.exhausted)
        c.stop()
    }

    @Test
    fun repairsWaitForTheForegroundGrace() = runTest {
        val stage = Fixture(this)
        val (c, link, _) = stage.liveMember()
        c.setApplicationActive(false)
        stage.tick()
        assertEquals(1, link.keepalives)
        assertEquals(0, link.repairTicks, "no repair while in the background")
        c.setApplicationActive(true)
        assertEquals(listOf(false, true), stage.host.activity)
        repeat(3) { stage.tick() }
        assertEquals(0, link.repairTicks, "the first 3 s after a return belong to the pictures")
        stage.tick()
        assertEquals(1, link.repairTicks)
        c.stop()
    }

    @Test
    fun bluetoothTurnsWaitForAddsAndScansAndGoInOrder() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val c = stage.coordinator
        for ((slot, name) in listOf("Camera A", "Camera B").withIndex()) {
            val camera = FakeStationCamera(name)
            stage.links[slot].place(camera, "192.168.1.1${slot + 2}")
            c.add(camera, slot)
        }
        val gate = FakeGate()
        stage.commissioner.connectGate = gate
        val third = FakeStationCamera("Camera C")
        stage.links[2].place(third, "192.168.1.14")
        val adding = launch { c.add(third, 2) }
        runCurrent()
        assertEquals(1, gate.waiting)
        val grants = mutableListOf<Pair<Int, Boolean>>()
        var holding = 0
        var overlapped = false
        for (slot in 0..1) {
            stage.links[slot].repairStep = { context ->
                MultiviewRepairStep.Repair {
                    val release = context.bluetoothTurn() ?: return@Repair MultiviewRepairResult.Done
                    holding += 1
                    if (holding > 1) overlapped = true
                    grants += slot to c.connectingCameras
                    kotlinx.coroutines.yield()
                    holding -= 1
                    release()
                    MultiviewRepairResult.Done
                }
            }
        }
        stage.tick()
        assertTrue(c.members[0].recovering && c.members[1].recovering)
        assertTrue(grants.isEmpty(), "no turn while an add commissions a camera")
        gate.open()
        adding.join()
        runCurrent()
        assertEquals(listOf(0, 1), grants.map { it.first }, "turns go in request order")
        assertTrue(grants.none { it.second })
        assertFalse(overlapped, "one holder at a time")
        c.stop()
    }

    @Test
    fun recordAvailabilityFollowsThreeSecondFreshness() = runTest {
        val stage = Fixture(this)
        val (c, link, member) = stage.liveMember()
        link.recordReport = MultiviewRecordReport(false, currentTime)
        stage.tick()
        assertTrue(member.recordingAvailable)
        stage.tick(2.seconds)
        assertFalse(member.recordingAvailable)
        assertEquals(false, c.tile(0, readings())?.actions?.first { it.id == MultiviewCameraAction.RECORD }?.enabled)
        link.recordReport = MultiviewRecordReport(false, currentTime)
        stage.tick()
        assertTrue(member.recordingAvailable)
        assertEquals(true, c.tile(0, readings())?.actions?.first { it.id == MultiviewCameraAction.RECORD }?.enabled)

        link.fakeSession.cameraReportsStatus()
        link.fakeSession.setLiveViewReady(true)
        assertTrue(c.recordPlan(null).isExecutable)
        link.fakeSession.cameraReportsRecording(null)
        assertTrue(c.recordPlan(null).isRefused, "strict: one unknown record state refuses all")
        assertFalse(c.canRecordTogether)
        c.stop()
    }

    @Test
    fun recordWritesEachOutcomeOnItsMemberAndTheGroupSummary() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val c = stage.coordinator
        for ((slot, name) in listOf("Camera A", "Camera B").withIndex()) {
            val camera = FakeStationCamera(name)
            stage.links[slot].place(camera, "192.168.1.1${slot + 2}")
            c.add(camera, slot)
            stage.links[slot].fakeSession.cameraReportsStatus()
            stage.links[slot].fakeSession.setLiveViewReady(true)
        }
        val a = stage.links[0].fakeSession
        val b = stage.links[1].fakeSession
        b.silenceReports(true)
        val plan = c.recordPlan(null)
        assertEquals(RecordDirection.START, plan.direction)
        val recording = launch { c.record(plan, together = true) }
        runCurrent()
        assertTrue(c.groupRecordingBusy)
        assertEquals("Starting cameras…", c.groupRecordingNote)
        assertTrue(a.wire.isNotEmpty() && b.wire.isNotEmpty())
        a.advance(1.seconds)
        b.advance(60.seconds)
        runCurrent()
        recording.join()
        assertEquals("Recording", c.members[0].recordingNote)
        assertEquals("No confirmation · check camera", c.members[1].recordingNote)
        assertEquals("1 of 2 confirmed · check camera tiles", c.groupRecordingNote)
        assertFalse(c.groupRecordingBusy)
        c.stop()
    }

    @Test
    fun theConfirmationWindowConfirmsRefusesOrTimesOut() = runTest {
        suspend fun run(
            current: Boolean = true,
            reply: Boolean? = null,
            report: (Long) -> MultiviewRecordReport? = { null },
            wait: Long = 100,
        ): Pair<MultiviewRecordConfirmation.Outcome, Boolean> {
            val sent = currentTime
            var acknowledged = false
            val waiting = async {
                MultiviewRecordConfirmation.wait(
                    start = true, sentAtMillis = sent, clock = { currentTime }, current = { current },
                    reply = { reply }, report = { report(sent) }, acknowledged = { acknowledged = true },
                )
            }
            runCurrent()
            advanceTimeBy(wait.milliseconds)
            runCurrent()
            return waiting.await() to acknowledged
        }
        val confirmed = run(reply = true, report = { MultiviewRecordReport(true, it + 50) })
        assertEquals(MultiviewRecordConfirmation.Outcome.CONFIRMED, confirmed.first)
        assertTrue(confirmed.second)
        assertEquals(MultiviewRecordConfirmation.Outcome.REFUSED, run(reply = false).first)
        assertEquals(MultiviewRecordConfirmation.Outcome.UNCONFIRMED, run(current = false).first, "a replaced link ends the wait")
        assertEquals(MultiviewRecordConfirmation.Outcome.UNCONFIRMED, run(wait = 8_000).first, "8 s without a report")
        assertEquals(
            MultiviewRecordConfirmation.Outcome.UNCONFIRMED,
            run(report = { MultiviewRecordReport(true, it - 1_000) }, wait = 8_000).first,
            "only a newer report confirms",
        )
    }

    @Test
    fun liveViewNeedsAControlledMemberAndClosesTheEditorFirst() = runTest {
        val stage = Fixture(this)
        val c = stage.coordinator
        stage.host.opensLiveView = true
        c.members[0].camera = FakeStationCamera("Camera A")
        assertFalse(c.openLiveView(0), "no control path yet")
        assertTrue(stage.host.liveViews.isEmpty())
        assertEquals(1, stage.host.editorsClosed, "the editor closes first")
        c.members[0].controlHost = "192.168.1.12"
        c.members[0].recovering = true
        assertFalse(c.openLiveView(0), "not while the picture is restored")
        c.members[0].recovering = false
        assertTrue(c.openLiveView(0))
        assertEquals(listOf(0), stage.host.liveViews)
    }

    @Test
    fun removeClearsTheMemberWithoutACameraCommand() = runTest {
        val stage = Fixture(this)
        val (c, link, member) = stage.liveMember()
        val camera = assertNotNull(member.camera)
        member.recordingBusy = true
        assertFalse(c.remove(0), "not while a record command waits")
        member.recordingBusy = false
        member.lutEnabled = false
        assertTrue(c.remove(0))
        assertTrue(member.camera == null && member.identity == null && member.controlHost == null)
        assertTrue(member.status == MultiviewCopy.ADD_CAMERA && member.lutEnabled && !member.publishing)
        assertTrue(link.closes >= 1)
        assertTrue(stage.host.changes.contains(0 to MultiviewMemberChange.REMOVED))
        assertTrue(link.fakeSession.wire.isEmpty(), "removing never commands the camera")
        assertEquals(emptyList(), stage.journal?.cameras)
        val probes = link.probes.size
        c.add(camera, 0)
        assertEquals("192.168.1.12", link.opens.last().first, "the same camera again: its address first")
        assertEquals(probes, link.probes.size, "found there without a search")
        c.stop()
    }

    @Test
    fun tileValuesFollowPocketIOS() = runTest {
        val stage = Fixture(this)
        val (c, link, member) = stage.liveMember()
        assertNull(c.tile(1, readings()), "an empty slot has no tile")
        link.recordReport = MultiviewRecordReport(false, currentTime)
        member.recordingAvailable = true
        var tile = c.tile(0, readings(hasPicture = true))
        assertNull(tile?.status)
        assertEquals("STBY", tile?.tally)
        assertEquals(listOf("liveView", "record", "lut", "reconnect", "remove"), tile?.actions?.map { it.id })
        assertTrue(tile?.actions?.all { it.enabled } == true)
        member.recordingNote = "Recording"
        assertNull(c.tile(0, readings(hasPicture = true))?.tileNote, "plain confirmations stay off the tile")
        member.recordingNote = "No confirmation · check camera"
        assertEquals("No confirmation · check camera", c.tile(0, readings(hasPicture = true))?.tileNote)

        member.recovering = true
        tile = c.tile(0, readings(hasPicture = true))
        assertEquals("Restoring picture…", tile?.status?.text)
        assertEquals(true, tile?.status?.inProgress)
        assertEquals("HOLD", tile?.tally)
        member.recovering = false

        member.identity = null
        member.failureMessage = MultiviewCopy.COULD_NOT_RESTORE
        tile = c.tile(0, readings(hasPicture = true))
        assertEquals("Connection failed · Options", tile?.status?.text)
        assertEquals(MultiviewCopy.COULD_NOT_RESTORE, tile?.status?.detail)
        assertEquals(false, tile?.status?.inProgress)
        assertEquals("CHECK", tile?.tally)
        assertTrue(tile?.actions?.map { it.id }?.contains("experimental") == true)

        member.failureMessage = null
        member.camera = FakeStationCamera("NoPreview camera")
        tile = c.tile(0, readings(hasPicture = false))
        assertEquals("Remove this camera to enable group recording for your other cameras.", tile?.footnote)
        assertEquals(false, tile?.actions?.first { it.id == "lut" }?.enabled)
        assertFalse(tile?.actions?.any { it.id == "reconnect" } == true)
        c.stop()
    }

    @Test
    fun withoutACommissionerTheCameraOpensAtItsSightingAndKeepsItsProvenIdentity() = runTest {
        val stage = Fixture(this, commissioner = false, discoversByProbe = false)
        stage.configure()
        val camera = FakeStationCamera("Body A", sightedAt = "192.168.1.13")
        stage.links[0].place(camera, "192.168.1.13")
        stage.coordinator.add(camera, 0)
        val member = stage.coordinator.members[0]
        assertEquals(listOf("192.168.1.13"), stage.links[0].opens.map { it.first })
        assertNull(stage.links[0].opens.first().second, "a sighting has no proof to expect")
        assertContentEquals(camera.identity, member.identity, "the proof it gave is kept for Reconnect")
        assertEquals("192.168.1.13", member.controlHost)
        assertTrue(stage.links[0].probes.isEmpty(), "never probed")
        stage.coordinator.stop()
    }

    @Test
    fun withoutProbeDiscoveryARejoinReopensTheKnownAddressOnly() = runTest {
        val stage = Fixture(this, commissioner = false, discoversByProbe = false)
        stage.configure()
        val camera = FakeStationCamera("Body A", sightedAt = "192.168.1.13")
        stage.links[0].place(camera, "192.168.1.13")
        stage.coordinator.add(camera, 0)
        stage.links[0].answering.clear()
        stage.coordinator.connectPreview(0)
        assertEquals(listOf("192.168.1.13", "192.168.1.13"), stage.links[0].opens.map { it.first })
        assertTrue(stage.links[0].probes.isEmpty())
        assertEquals(MultiviewCopy.COULD_NOT_RESTORE, stage.coordinator.members[0].failureMessage)
        stage.coordinator.stop()
    }

    @Test
    fun hostsCompareByTheirKey() = runTest {
        val stage = Fixture(this, hostKey = true)
        stage.configure()
        val c = stage.coordinator
        c.members[1].camera = FakeStationCamera("Camera B")
        c.members[1].controlHost = "192.168.001.012"
        val camera = FakeStationCamera("Camera A")
        stage.links[0].place(camera, "192.168.1.12")
        c.add(camera, 0)
        assertFalse("192.168.1.12" in stage.links[0].probes, "another member's host, in another form")
        assertEquals(MultiviewCopy.NOT_FOUND, c.members[0].failureMessage)
        c.stop()
    }

    @Test
    fun bluetoothTurnsResumeWhenAReconnectEnds() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val c = stage.coordinator
        for ((slot, name) in listOf("Camera A", "Camera B").withIndex()) {
            val camera = FakeStationCamera(name)
            stage.links[slot].place(camera, "192.168.1.1${slot + 2}")
            c.add(camera, slot)
        }
        val gate = FakeGate()
        stage.links[1].openGate = gate
        val reconnecting = launch { c.connectPreview(1) }
        runCurrent()
        assertEquals(1, gate.waiting)
        var granted = false
        stage.links[0].repairStep = { context ->
            MultiviewRepairStep.Repair {
                val release = context.bluetoothTurn() ?: return@Repair MultiviewRepairResult.Done
                granted = true
                release()
                MultiviewRepairResult.Done
            }
        }
        stage.tick()
        assertTrue(c.members[0].recovering)
        assertFalse(granted, "no turn while another member connects")
        gate.open()
        reconnecting.join()
        runCurrent()
        assertTrue(granted)
        c.stop()
    }

    @Test
    fun aRemovedMembersCancelledRepairChangesNothing() = runTest {
        val stage = Fixture(this)
        val (c, link, member) = stage.liveMember()
        val gate = FakeGate()
        // A repair that ignores cancellation and gives up late.
        link.repairStep = {
            MultiviewRepairStep.Repair {
                withContext(NonCancellable) { gate.await() }
                MultiviewRepairResult.WaitForOperator("Late verdict")
            }
        }
        stage.tick()
        assertEquals(1, gate.waiting)
        assertTrue(member.recovering)
        link.repairStep = { MultiviewRepairStep.Healthy }
        assertTrue(c.remove(0))
        gate.open()
        runCurrent()
        // The same camera comes back into the emptied slot.
        val camera = FakeStationCamera("Camera A")
        link.place(camera, "192.168.1.12")
        c.add(camera, 0)
        assertNull(member.failureMessage, "a removed member's late verdict changes nothing")
        assertFalse(member.budget.exhausted)
        assertTrue(member.publishing)
        c.stop()
    }

    @Test
    fun aReconnectSearchStartsNoRepairOnTheClosedLink() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val c = stage.coordinator
        for ((slot, name) in listOf("Camera A", "Camera B").withIndex()) {
            val camera = FakeStationCamera(name)
            stage.links[slot].place(camera, "192.168.1.1${slot + 2}")
            c.add(camera, slot)
        }
        // B's known address now belongs to A's control path, and B answers nowhere: the search
        // waits between its passes with B's link closed.
        c.members[1].address = "192.168.1.12"
        stage.links[1].answering.clear()
        val reconnecting = launch { c.reconnect(1) }
        runCurrent()
        assertTrue(c.members[1].connecting)
        val repairs = stage.links[1].repairTicks
        stage.tick()
        assertTrue(c.members[1].connecting, "the search still waits between its passes")
        assertEquals(repairs, stage.links[1].repairTicks, "no repair on a link the search closed")
        reconnecting.cancel()
        c.stop()
    }

    @Test
    fun anOlderRepairNeverClearsANewerOne() = runTest {
        val stage = Fixture(this)
        val (c, link, member) = stage.liveMember()
        val older = FakeGate()
        val newer = FakeGate()
        link.repairStep = {
            MultiviewRepairStep.Repair {
                withContext(NonCancellable) { older.await() }
                MultiviewRepairResult.Done
            }
        }
        stage.tick()
        assertEquals(1, older.waiting)
        assertTrue(c.remove(0))
        val camera = FakeStationCamera("Camera B")
        link.place(camera, "192.168.1.12")
        link.repairStep = {
            MultiviewRepairStep.Repair {
                newer.await()
                MultiviewRepairResult.Done
            }
        }
        c.add(camera, 0)
        stage.tick()
        assertEquals(1, newer.waiting)
        assertTrue(member.recovering)
        older.open()
        runCurrent()
        assertTrue(member.recovering, "the newer repair still owns the member")
        newer.open()
        runCurrent()
        assertFalse(member.recovering)
        c.stop()
    }

    @Test
    fun thePickerListsFoundCamerasThatMayJoinAndAreNotMembers() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val c = stage.coordinator
        val a = FakeStationCamera("Camera A")
        val limited = FakeStationCamera("NoPreview B")
        val member = FakeStationCamera("Camera M")
        c.members[1].camera = member
        c.found = listOf(a, limited, FakeStationCamera("Unqualified U"), member)
        assertEquals(
            listOf(
                MultiviewPickerRow(a.record.id, "Camera A"),
                MultiviewPickerRow(limited.record.id, "NoPreview B", detail = MultiviewCopy.PREVIEW_UNAVAILABLE, limited = true),
            ),
            c.pickerRows(),
        )
        assertEquals("Each camera will join Test network. Approve on the camera if asked.", c.pickerFooter)
        assertEquals(MultiviewNetworkRestore.CAMERA_NETWORKS, c.networkRestore)
        assertFalse(c.scansNetworks)
        stage.commissioner.scansNetworks = true
        assertTrue(c.scansNetworks)
        assertEquals("Camera M", c.cameraName(1))
        assertNull(c.cameraName(0))
        c.stop()

        val passive = Fixture(this, commissioner = false, discoversByProbe = false)
        assertEquals(MultiviewNetworkRestore.NONE, passive.coordinator.networkRestore)
        assertFalse(passive.coordinator.scansNetworks)
    }

    @Test
    fun pickingARowWithoutPreviewAddsItExperimentally() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val c = stage.coordinator
        val camera = FakeStationCamera("NoPreview B")
        stage.links[0].place(camera, "192.168.1.12")
        c.found = listOf(camera)
        assertFalse(c.enqueueAdd("unknown-row", 0), "an unknown row adds nothing")
        assertTrue(c.enqueueAdd(camera.record.id, 0))
        runCurrent()
        assertTrue(c.members[0].networkVerified && !c.members[0].connecting)
        assertTrue(c.members[0].experimental)
        assertEquals(MultiviewCopy.VERIFIED_WITHOUT_PREVIEW, c.members[0].status)
        assertTrue(c.pickerRows().isEmpty(), "a member is no longer offered")
        c.stop()
    }

    @Test
    fun theExperimentalJoinShowsOnlyWhereTheCommissionerOffersIt() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val c = stage.coordinator
        val limited = FakeStationCamera("NoPreview B")
        c.found = listOf(limited)
        c.members[0].camera = FakeStationCamera("Camera A")
        c.members[0].failureMessage = MultiviewCopy.NOT_FOUND
        fun experimental(tile: MultiviewTile?) = tile?.actions?.any { it.id == MultiviewCameraAction.EXPERIMENTAL } == true
        assertTrue(c.offersExperimentalJoin)
        assertTrue(experimental(c.stageTile(0)), "a failed camera may try the experimental path")
        stage.commissioner.joinsExperimentally = false
        assertFalse(c.offersExperimentalJoin)
        assertFalse(experimental(c.stageTile(0)), "a commissioner without it never offers it")
        assertEquals(
            listOf(MultiviewPickerRow(limited.record.id, "NoPreview B", limited = true)),
            c.pickerRows(),
            "a camera without a picture joins the normal way, without the experimental copy",
        )
        c.tryExperimentalNetwork(0)
        assertTrue(c.members[0].camera != null && stage.commissioner.joins.isEmpty(), "nothing to try")
        stage.links[1].place(limited, "192.168.1.13")
        assertTrue(c.enqueueAdd(limited.record.id, 1))
        runCurrent()
        assertTrue(!c.members[1].connecting && c.members[1].camera != null)
        assertFalse(c.members[1].experimental)
        assertEquals(listOf(false), stage.commissioner.joins.map { it.third })
        c.stop()

        val passive = Fixture(this, commissioner = false, discoversByProbe = false)
        passive.coordinator.members[0].camera = FakeStationCamera("Body A")
        passive.coordinator.members[0].failureMessage = MultiviewCopy.NOT_FOUND
        assertFalse(passive.coordinator.offersExperimentalJoin)
        assertFalse(experimental(passive.coordinator.stageTile(0)), "nothing to join through")
    }

    @Test
    fun anAddAsksForApprovalOnlyWhereTheCommissionerDoes() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val c = stage.coordinator
        // The add's first status shows while this phone rejoins the network.
        val gate = FakeGate()
        stage.path.joinGate = gate
        val a = FakeStationCamera("Camera A")
        stage.links[0].place(a, "192.168.1.12")
        val adding = launch { c.add(a, 0) }
        runCurrent()
        assertEquals(1, gate.waiting)
        assertEquals(MultiviewCopy.APPROVE_ON_CAMERA, c.members[0].status)
        assertEquals("Each camera will join Test network. Approve on the camera if asked.", c.pickerFooter)
        gate.open()
        adding.join()
        stage.commissioner.asksApprovalOnCamera = false
        val b = FakeStationCamera("Camera B")
        stage.links[1].place(b, "192.168.1.13")
        val gateB = FakeGate()
        stage.path.joinGate = gateB
        val addingB = launch { c.add(b, 1) }
        runCurrent()
        assertEquals(1, gateB.waiting)
        assertEquals(MultiviewCopy.CONNECTING_PREVIEW, c.members[1].status, "nothing asks on the camera")
        assertEquals("Each camera will join Test network.", c.pickerFooter)
        gateB.open()
        addingB.join()
        c.stop()
    }

    @Test
    fun aWizardWithoutAScanSaysTheCameraCannotListNetworks() = runTest {
        val stage = Fixture(this)
        assertNull(stage.coordinator.wizardScan.scan)
        assertFalse(stage.coordinator.wizardScan.cameraScansNetworks, "Nearby says the camera can\u2019t list networks")
        stage.commissioner.scansNetworks = true
        assertNotNull(stage.coordinator.wizardScan.scan)
        assertTrue(stage.coordinator.wizardScan.cameraScansNetworks)
    }

    @Test
    fun theScreenStartsTheStageAndOpensTheWizardFirst() = runTest {
        val stage = Fixture(this)
        val c = stage.coordinator
        assertTrue(c.choosesNetwork)
        assertTrue(c.screenAppeared(startsSession = true), "a new stage asks for its network")
        assertTrue(c.running && !c.networkConfigured)
        assertTrue(c.screenAppeared(startsSession = true), "appearing again starts nothing new")
        c.stop()

        val review = Fixture(this)
        review.coordinator.networkConfigured = true
        assertFalse(review.coordinator.screenAppeared(startsSession = false))
        assertFalse(review.coordinator.running, "a review fixture is never started")
    }

    @Test
    fun withoutACommissionerTheStageUsesThePhonesNetworkWithoutTheWizard() = runTest {
        val passive = Fixture(this, commissioner = false, discoversByProbe = false)
        val c = passive.coordinator
        assertFalse(c.choosesNetwork)
        assertFalse(c.screenAppeared(startsSession = true), "no network wizard")
        assertTrue(c.running && c.networkConfigured, "cameras already share this phone's network")
        assertEquals("Cameras on this phone\u2019s network appear here.", c.pickerFooter)
        val camera = FakeStationCamera("Body A", sightedAt = "192.168.1.13")
        passive.links[0].place(camera, "192.168.1.13")
        c.add(camera, 0)
        assertEquals("192.168.1.13", c.members[0].controlHost)
        assertTrue(passive.path.joins.isEmpty(), "the phone stays on its own network")
        assertTrue(passive.savedNetworks.isEmpty(), "a network without a name is never saved")
        c.stop()
    }

    @Test
    fun aRemoveQueuedBeforeTheVerdictLandsChangesNothing() = runTest {
        val stage = Fixture(this)
        val (c, link, member) = stage.liveMember()
        val gate = FakeGate()
        val test = this
        // The operator's Remove reaches the main dispatcher before the repair's verdict does.
        link.repairStep = {
            MultiviewRepairStep.Repair {
                withContext(NonCancellable) { gate.await() }
                test.launch { c.remove(0) }
                MultiviewRepairResult.WaitForOperator("Late verdict")
            }
        }
        stage.tick()
        assertEquals(1, gate.waiting)
        assertTrue(member.recovering)
        link.repairStep = { MultiviewRepairStep.Healthy }
        gate.open()
        runCurrent()
        assertNull(member.camera)
        val camera = FakeStationCamera("Camera A")
        link.place(camera, "192.168.1.12")
        c.add(camera, 0)
        assertNull(member.failureMessage, "the removed member's verdict changes nothing")
        assertFalse(member.budget.exhausted)
        assertTrue(member.publishing)
        c.stop()
    }

    @Test
    fun lutTogglesFollowTheMembersAndTheJournal() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val c = stage.coordinator
        c.members[0].camera = FakeStationCamera("Camera A")
        c.members[1].camera = FakeStationCamera("Camera B")
        assertTrue(c.lutOn)
        c.toggleLUT(0)
        assertTrue(!c.members[0].lutEnabled && c.members[1].lutEnabled)
        assertEquals(listOf(0), stage.host.lutChanges)
        assertEquals(listOf(false, true), stage.journal?.cameras?.map { it.lutEnabled })
        assertTrue(c.lutOn, "one camera still grades its picture")
        c.toggleLUT()
        assertTrue(c.members[0].lutEnabled && c.members[1].lutEnabled, "a mixed stage turns every LUT on")
        assertEquals(listOf(0, 0), stage.host.lutChanges)
        c.toggleLUT()
        assertTrue(!c.members[0].lutEnabled && !c.members[1].lutEnabled)
        assertEquals(listOf(0, 0, 0, 1), stage.host.lutChanges)
        assertFalse(c.lutOn)
        assertEquals(listOf(false, false), stage.journal?.cameras?.map { it.lutEnabled })
        c.stop()
    }

    @Test
    fun stageTilesUseTheHostsReadingsAndCapabilities() = runTest {
        val stage = Fixture(this)
        val c = stage.coordinator
        c.members[0].camera = FakeStationCamera("Camera A")
        c.members[1].camera = FakeStationCamera("Camera B")
        val readouts = listOf(MultiviewReadout("ISO", "800"))
        stage.host.readings[0] = MultiviewTileReadings("Wide", readouts = readouts, hasPicture = true)
        assertEquals("Wide", c.stageTile(0)?.name)
        assertEquals("Camera B", c.stageTile(1)?.name, "without readings the tile names its camera")
        assertNull(c.stageTile(2))
        assertFalse(c.stageTile(0)!!.actions.any { it.id == MultiviewCameraAction.LUT })
        assertEquals(MultiviewToolAvailability(), c.toolAvailability)
        stage.host.autoLUT = true
        stage.host.edits = true
        assertTrue(c.stageTile(0)!!.actions.any { it.id == MultiviewCameraAction.LUT })
        assertEquals(MultiviewToolAvailability(setOf(0, 1), setOf(0, 1)), c.toolAvailability)
        assertEquals(listOf(0, 1), c.cameraSettingsSlots)
        c.presentation.selected = 0
        assertEquals(readouts, c.programReadouts)
        c.presentation.selected = 2
        assertNull(c.programReadouts, "an empty program slot shows no values")
    }

    @Test
    fun controlsWaitForWhatOnlyTheAppAdmits() = runTest {
        val stage = Fixture(this)
        val (c, _, member) = stage.liveMember()
        member.recordingAvailable = true
        assertTrue(c.controlsAvailable(0))
        stage.host.admits = false
        assertFalse(c.controlsAvailable(0), "the app's own link or Live View decides too")
        c.stop()
    }

    @Test
    fun aCancelledCloseStillEnds() = runTest {
        val stage = Fixture(this)
        val gate = FakeGate()
        stage.commissioner.restoreGate = gate
        val camera = FakeStationCamera("Scan camera")
        stage.coordinator.recordStationChange(camera)
        val closing = launch { stage.coordinator.closeStage() }
        runCurrent()
        assertEquals(1, gate.waiting)
        closing.cancel()
        runCurrent()
        gate.open()
        runCurrent()
        assertFalse(stage.coordinator.closing)
        assertNull(stage.journal, "the camera's return finishes for a cancelled caller")
        assertTrue(stage.coordinator.closeStage(), "the stage closes again")
    }

    /** Kotlin only: a Swift return cannot throw. */
    @Test
    fun aReturnThatThrowsStaysForTheNextClose() = runTest {
        val stage = Fixture(this)
        val camera = FakeStationCamera("Scan camera")
        stage.commissioner.restoreError = CancellationException("the return was cancelled")
        stage.coordinator.recordStationChange(camera)
        assertFalse(stage.coordinator.closeStage())
        assertTrue(stage.coordinator.hasPendingCleanup)
        assertEquals(listOf(camera.id), stage.journal?.pendingReset?.map { it.id })
        stage.commissioner.restoreError = IllegalStateException("radio unavailable")
        assertFalse(stage.coordinator.closeStage())
        stage.commissioner.restoreError = null
        assertTrue(stage.coordinator.closeStage())
        assertEquals(listOf(camera.id, camera.id, camera.id), stage.commissioner.restores)
        assertNull(stage.journal)
    }

    /** Kotlin only: Swift's links cannot throw from these steps. */
    @Test
    fun aLinkThatThrowsFailsOnlyItsMember() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val c = stage.coordinator
        val camera = FakeStationCamera("Camera A")
        stage.links[0].probeErrors["192.168.1.9"] = IllegalStateException("socket refused")
        stage.links[0].place(camera, "192.168.1.12")
        c.add(camera, 0)
        val member = c.members[0]
        assertTrue(member.publishing, "a probe that throws is a host that did not answer")
        stage.links[0].keepaliveError = IllegalStateException("socket gone")
        stage.links[0].repairStep = { MultiviewRepairStep.Repair { throw IllegalStateException("repair broke") } }
        stage.tick()
        assertEquals(MultiviewCopy.COULD_NOT_RESTORE, member.failureMessage)
        assertFalse(member.recovering)
        assertEquals(1, stage.links[1].keepalives, "the other members keep their monitor")
        c.stop()
    }

    @Test
    fun removeForgetsTheAddressForAnotherCamera() = runTest {
        val stage = Fixture(this, commissioner = false, discoversByProbe = false)
        stage.configure()
        val c = stage.coordinator
        val a = FakeStationCamera("Body A", sightedAt = "192.168.1.12")
        val b = FakeStationCamera("Body B", sightedAt = "192.168.1.13")
        stage.links[0].place(a, "192.168.1.12")
        stage.links[0].place(b, "192.168.1.13")
        c.add(a, 0)
        assertTrue(c.remove(0))
        assertEquals("", c.members[0].address)
        c.add(b, 0)
        assertEquals(
            listOf("192.168.1.12", "192.168.1.13"), stage.links[0].opens.map { it.first },
            "the new camera is never opened at the removed camera's address",
        )
        assertContentEquals(b.identity, c.members[0].identity)
        c.stop()
    }

    @Test
    fun aMemberWhosePreviewStartedDuringItsJoinIsWatched() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val c = stage.coordinator
        val gate = FakeGate()
        stage.commissioner.verifiesOnJoin = true
        stage.commissioner.afterVerifyGate = gate
        val camera = FakeStationCamera("Camera A")
        stage.links[0].place(camera, "192.168.1.12")
        val adding = launch { c.add(camera, 0) }
        runCurrent()
        assertEquals(1, gate.waiting)
        assertTrue(c.members[0].publishing && c.members[0].connecting)
        stage.tick()
        assertEquals(1, stage.links[0].repairTicks, "the watchdog runs while the join finishes")
        gate.open()
        adding.join()
        c.stop()
    }

    @Test
    fun aDuplicateFoundWhileTheCameraJoinsIsFinal() = runTest {
        val stage = Fixture(this)
        stage.configure()
        val c = stage.coordinator
        val camera = FakeStationCamera("Camera A")
        c.members[1].camera = FakeStationCamera("Camera B")
        c.members[1].identity = camera.identity // the same body, already a member
        stage.commissioner.lostJoinReply = true
        stage.links[0].place(camera, "192.168.1.12")
        c.add(camera, 0)
        assertEquals(MultiviewCopy.DUPLICATE, c.members[0].failureMessage)
        assertEquals(listOf("192.168.1.12"), stage.links[0].opens.map { it.first }, "the search stops there")
        c.stop()
    }

    /** Swift returns `unconfirmed`; Kotlin's wait ends with the caller's cancellation. */
    @Test
    fun aCancelledConfirmationWaitEndsAtOnce() = runTest {
        val waiting = launch {
            MultiviewRecordConfirmation.wait(
                start = true, sentAtMillis = 0, clock = { currentTime }, current = { true },
                reply = { null }, report = { null }, acknowledged = {},
            )
        }
        runCurrent()
        waiting.cancel()
        runCurrent()
        assertTrue(waiting.isCompleted)
        assertEquals(0, currentTime, "no time passed")
    }
}

private fun journalCamera(slot: Int): MultiviewStageJournal.Camera = MultiviewStageJournal.Camera(
    slot = slot, id = java.util.UUID.randomUUID().toString(), name = "Camera-Test", address = "",
    experimental = false, lutEnabled = false,
)

private fun readings(hasPicture: Boolean = true): MultiviewTileReadings = MultiviewTileReadings("Camera", hasPicture = hasPicture)

private class RecordingHost : MultiviewHost {
    val changes = mutableListOf<Pair<Int, MultiviewMemberChange>>()
    val activity = mutableListOf<Boolean>()
    val liveViews = mutableListOf<Int>()
    var editorsClosed = 0
    var opensLiveView = false
    val readings = mutableMapOf<Int, MultiviewTileReadings>()
    val lutChanges = mutableListOf<Int>()
    var autoLUT = false
    var edits = false
    var admits = true

    override val appliesAutoLUT: Boolean get() = autoLUT
    override val editsCameraSettings: Boolean get() = edits

    override fun readings(slot: Int): MultiviewTileReadings? = readings[slot]

    override fun lutChanged(slot: Int) {
        lutChanges += slot
    }

    override fun admitsControls(slot: Int): Boolean = admits

    override fun openLiveView(slot: Int): Boolean {
        if (!opensLiveView) return false
        liveViews += slot
        return true
    }

    override fun closeEditors() {
        editorsClosed += 1
    }

    override fun memberChanged(slot: Int, change: MultiviewMemberChange) {
        changes += slot to change
    }

    override fun applicationActivityChanged(active: Boolean) {
        activity += active
    }
}

/** One coordinator over fakes: four slots on 192.168.1.8/29 (this phone .10), on the test's virtual clock. */
@OptIn(ExperimentalCoroutinesApi::class)
private class Fixture(
    private val test: TestScope,
    saved: MultiviewStageJournal.Stage? = null,
    netmask: String = "255.255.255.248",
    commissioner: Boolean = true,
    discoversByProbe: Boolean = true,
    hostKey: Boolean = false,
    networkPath: MultiviewNetworkPath = MultiviewNetworkPath.CHOSEN,
) {
    val path = FakeStationHostPath(netmask = netmask)
    val commissioner = FakeStationCommissioner()
    val scanner = FakeNearbyScanner()
    val links = List(4) { FakeMemberLink() }
    val host = RecordingHost()
    var journal: MultiviewStageJournal.Stage? = saved
    val passwords = mutableMapOf<String, String>()
    val lookups = mutableListOf<Pair<String, Boolean>>()
    val savedNetworks = mutableListOf<StationNetwork>()
    val coordinator: MultiviewCoordinator<FakeStationCamera, FakeMemberLink> = MultiviewCoordinator(
        links = links,
        policy = MultiviewCameraPolicy(
            discoversByProbe = discoversByProbe,
            hostKey = if (hostKey) {
                { address -> address.split(".").joinToString(".") { (it.toIntOrNull() ?: 0).toString() } }
            } else {
                null
            },
            qualification = { camera, _ ->
                if (camera.name.startsWith("Unqualified")) {
                    MulticamQualification.Refused(MulticamQualificationRefusal.UNSUPPORTED_CONFIGURATION)
                } else {
                    MulticamQualification.Qualified
                }
            },
            hasPreview = { !it.name.startsWith("NoPreview") },
        ),
        commissioner = if (commissioner) this.commissioner else null,
        scanner = scanner,
        hostPath = path,
        describe = { it.record },
        journal = MultiviewJournalStorage(
            load = { journal },
            save = {
                journal = it
                true
            },
        ),
        networks = MultiviewNetworkStorage(
            password = { ssid, hotspot ->
                lookups += ssid to hotspot
                passwords["$ssid|$hotspot"]
            },
            save = { savedNetworks += it },
        ),
        scope = test.backgroundScope,
        sightingAddress = { it.sightedAt },
        clock = { test.testScheduler.currentTime },
        monotonic = { MonotonicInstant(test.testScheduler.currentTime.milliseconds) },
        networkPath = networkPath,
    ).also { it.host = host }

    /** Starts the stage and connects it to "Test network" over Wi-Fi. */
    suspend fun configure() {
        coordinator.start()
        coordinator.selectNetworkSource(false)
        coordinator.selectNetwork("Test network")
        assertTrue(coordinator.configureNetwork())
    }

    /** A configured stage with Camera A live in slot 0 at 192.168.1.12. */
    suspend fun liveMember(): Triple<MultiviewCoordinator<FakeStationCamera, FakeMemberLink>, FakeMemberLink, MultiviewMember<FakeStationCamera>> {
        configure()
        val camera = FakeStationCamera("Camera A")
        links[0].place(camera, "192.168.1.12")
        coordinator.add(camera, 0)
        assertTrue(coordinator.members[0].publishing)
        return Triple(coordinator, links[0], coordinator.members[0])
    }

    /** Moves the clock by [by] (default one monitor period) and runs what is due: one monitor tick. */
    fun tick(by: kotlin.time.Duration = 1.seconds) {
        test.advanceTimeBy(by)
        test.runCurrent()
    }
}
