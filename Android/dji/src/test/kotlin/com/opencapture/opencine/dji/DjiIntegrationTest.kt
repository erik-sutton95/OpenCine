package com.opencapture.opencine.dji

import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CameraServices
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.ConnectionEvent
import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionPrompt
import com.opencapture.opencine.core.DiscoveryMode
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.RouteDraft
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedRoute
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.djiLike
import com.opencapture.opencine.vocabulary.CameraModel
import com.opencapture.opencine.vocabulary.ConnectionPhase
import com.opencapture.opencine.vocabulary.FoundCamera
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import com.opencapture.opencine.core.ConnectionPhase as CorePhase

/** A scripted DJI session (Swift `FakeDJIPort`). */
private class FakeDjiPort : DjiConnectPort {
    override val found = MutableStateFlow<List<FoundCamera>>(emptyList())
    override val phaseFlow = MutableStateFlow(ConnectionPhase.IDLE)
    override val setupProgress = MutableStateFlow<String?>(null)
    override val failureDetail = MutableStateFlow<ConnectionFailure?>(null)
    override var joinedSSID: String? = null
    override val control: CameraSession = FakeCameraSession.djiLike()
    override var services = CameraServices()
    var scans = 0
    var scanStops = 0
    var disconnects = 0
    val reconnects = mutableListOf<String>()
    val setups = mutableListOf<Triple<CameraConnectionSetup, MultiviewNetworkStore.Network?, Boolean>>()

    override fun startScan() { scans += 1 }
    override fun stopScan() { scanStops += 1 }
    override fun useSetup(setup: CameraConnectionSetup, network: MultiviewNetworkStore.Network?, restoreAccessPoint: Boolean) {
        setups += Triple(setup, network, restoreAccessPoint)
    }
    override fun reconnect(id: String) {
        reconnects += id
        phaseFlow.value = ConnectionPhase.CONNECTING_GATT
    }
    override fun disconnect() {
        disconnects += 1
        phaseFlow.value = ConnectionPhase.IDLE
    }
}

/** SIMULATED registration fact; no camera operation or fabricated readiness. */
private class RegisteredDjiService
private class UnregisteredDjiService

/** Swift suite `DJIIntegrationTests`, same method names. */
@OptIn(ExperimentalCoroutinesApi::class)
class DjiIntegrationTest {
    private val pocket = FoundCamera("cam-1", "AA:BB", "OsmoPocket3-AAAA", djiBodyProfile("Osmo Pocket 3"), 0x20)
    private val ap = SavedRoute(key = "ap", kind = RouteKind.CAMERA_ACCESS_POINT, network = "OsmoPocket3-AAAA", bluetooth = true)
    private val wifi = SavedRoute(key = "wifi", kind = RouteKind.INFRASTRUCTURE_NETWORK, network = "studio", bluetooth = true)
    private val saved = SavedCamera(
        id = "cam-1", integration = DjiCameraSessionAdapter.INTEGRATION, advertisedName = "OsmoPocket3-AAAA",
        model = "Osmo Pocket 3", routes = listOf(ap, wifi), preferredRoute = ap.id,
    )
    private val savedNetworks = mutableListOf<Triple<String, String, Boolean>>()
    private val forgotten = mutableListOf<String>()

    private fun integration(port: FakeDjiPort) = DjiIntegration(
        port,
        loadNetwork = { ssid, hotspot -> MultiviewNetworkStore.Network(ssid, "pw-$ssid", hotspot) },
        saveNetwork = { ssid, password, hotspot -> savedNetworks += Triple(ssid, password, hotspot) },
        forgetCredentials = { forgotten += it },
        now = { 1_759_307_200_000 },
    )

    private fun TestScope.collect(events: Flow<ConnectionEvent>): MutableList<ConnectionEvent> {
        val seen = mutableListOf<ConnectionEvent>()
        backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) { events.collect { seen += it } }
        return seen
    }

    @Test
    fun connectedForwardsOptionalServicesAndKeepsSessionOwner() = runTest {
        val port = FakeDjiPort()
        val service = RegisteredDjiService()
        port.services = CameraServices().plus(RegisteredDjiService::class, service)
        port.found.value = listOf(pocket)
        val events = collect(integration(port).connect(ConnectTarget.Nearby(NearbyCamera(
            "cam-1", name = "OsmoPocket3-AAAA", model = "Osmo Pocket 3",
            routes = setOf(RouteKind.CAMERA_ACCESS_POINT),
        ))))
        runCurrent()
        port.phaseFlow.value = ConnectionPhase.LIVE
        runCurrent()
        val camera = assertIs<ConnectionEvent.Connected>(events.last()).camera
        assertEquals(port.control.id, camera.session.id)
        assertTrue(camera.services.get<RegisteredDjiService>() === service)
        assertEquals(null, camera.services.get<UnregisteredDjiService>())
    }

    @Test
    fun legacyConnectionKeepsOptionalServicesAbsent() = runTest {
        val port = FakeDjiPort()
        port.found.value = listOf(pocket)
        val events = collect(integration(port).connect(ConnectTarget.Nearby(NearbyCamera(
            "cam-1", name = "OsmoPocket3-AAAA", model = "Osmo Pocket 3",
            routes = setOf(RouteKind.CAMERA_ACCESS_POINT),
        ))))
        runCurrent()
        port.phaseFlow.value = ConnectionPhase.LIVE
        runCurrent()
        val camera = assertIs<ConnectionEvent.Connected>(events.last()).camera
        assertEquals(null, camera.services.get<RegisteredDjiService>())
    }

    @Test
    fun discoveryListensPassivelyOverBluetooth() = runTest {
        val port = FakeDjiPort()
        val dji = integration(port)
        assertTrue(dji.discover(DiscoveryMode.ACTIVE).toList().isEmpty())
        val lists = mutableListOf<List<NearbyCamera>>()
        val job = backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) { dji.discover(DiscoveryMode.PASSIVE).collect { lists += it } }
        port.found.value = listOf(pocket)
        runCurrent()
        assertEquals(listOf("OsmoPocket3-AAAA"), lists.last().map { it.name })
        assertTrue(port.scans == 1 && port.reconnects.isEmpty(), "listening never connects")
        job.cancel()
        runCurrent()
        assertEquals(1, port.scanStops)
        assertTrue(dji.profiles.all { it.addableRoutes == DjiIntegration.MOVING_ROUTES })
    }

    @Test
    fun cameraWiFiStepsAndPrompts() = runTest {
        val port = FakeDjiPort()
        port.found.value = listOf(pocket)
        val events = collect(integration(port).connect(ConnectTarget.Nearby(NearbyCamera("cam-1", name = "OsmoPocket3-AAAA", model = "Osmo Pocket 3", routes = setOf(RouteKind.CAMERA_ACCESS_POINT)))))
        runCurrent()
        assertEquals(CameraConnectionSetup.CAMERA_WIFI, port.setups.single().first)
        for (phase in listOf(ConnectionPhase.PAIRING, ConnectionPhase.AWAITING_APPROVAL, ConnectionPhase.READING_WIFI_CREDS, ConnectionPhase.JOINING_WIFI, ConnectionPhase.OPENING_DATALINK)) {
            port.phaseFlow.value = phase
            runCurrent()
        }
        port.joinedSSID = "OsmoPocket3-AAAA"
        port.phaseFlow.value = ConnectionPhase.LIVE
        runCurrent()
        val progress = events.filterIsInstance<ConnectionEvent.Progress>()
        // The Wi-Fi step's caption is the phase label main showed when the session reports no progress.
        assertEquals(
            listOf(
                "LINK 0 - -", "AWAITING_APPROVAL 0 Approve on the camera -", "LINK 1 - Reading Wi-Fi credentials…",
                "JOINING_NETWORK 1 - Joining camera Wi-Fi…", "NEGOTIATING 2 - -",
            ),
            progress.map { "${it.progress.phase} ${it.progress.current} ${it.prompt?.text ?: "-"} ${it.progress.note ?: "-"}" },
        )
        assertEquals(
            listOf("Connecting over Bluetooth", "Joining camera Wi-Fi", "Opening the video link", "Starting the picture"),
            progress.first().progress.steps.map { it.title },
        )
        val record = assertIs<ConnectionEvent.Connected>(events.last()).camera.saved
        assertTrue(record.id == "cam-1" && record.lastConnected == 1_759_307_200_000 && record.extras == mapOf("modelId" to "32"))
        assertTrue(record.routes.single().network == "OsmoPocket3-AAAA" && record.preferredRoute == record.routes.single().id)
    }

    @Test
    fun aWiFiSetupMovesTheCamera() = runTest {
        val port = FakeDjiPort()
        val events = collect(integration(port).connect(ConnectTarget.Saved(saved, wifi.id)))
        runCurrent()
        assertEquals(Triple(CameraConnectionSetup.WIFI, MultiviewNetworkStore.Network("studio", "pw-studio", false), false), port.setups.single())
        port.setupProgress.value = "Finding the camera on studio"
        port.phaseFlow.value = ConnectionPhase.JOINING_WIFI
        runCurrent()
        val moving = events.filterIsInstance<ConnectionEvent.Progress>().last().progress
        assertEquals(listOf("Connecting over Bluetooth", "Moving the camera to studio", "Finding the camera", "Starting the picture"), moving.steps.map { it.title })
        assertEquals(2, moving.current)
        port.failureDetail.value = DjiFailures.classify(StationJoin.Failure.JoinRejected(), ConnectionPhase.JOINING_WIFI, "The camera could not join the Wi-Fi.")
        port.phaseFlow.value = ConnectionPhase.FAILED
        runCurrent()
        val failure = assertIs<ConnectionEvent.Failed>(events.last()).failure
        assertTrue(failure.reason == ConnectionFailure.Reason.CredentialsRejected && failure.title == "Couldn’t connect over studio")
        assertEquals(listOf(RecoveryAction.EditRoute(wifi.id), RecoveryAction.Retry, RecoveryAction.UseRoute(ap.id)), failure.actions)
    }

    @Test
    fun aWifiSetupKeepsTheFindingNoteWhileTheCameraMoves() = runTest {
        val port = FakeDjiPort()
        val events = collect(integration(port).connect(ConnectTarget.Saved(saved, wifi.id)))
        runCurrent()
        port.setupProgress.value = "Finding the camera on studio"
        port.phaseFlow.value = ConnectionPhase.JOINING_WIFI
        runCurrent()
        val finding = events.filterIsInstance<ConnectionEvent.Progress>().last().progress
        assertEquals(2, finding.current)
        assertEquals("Finding the camera on studio", finding.note)
    }

    @Test
    fun theFindingNoteFollowsTheSetupTextWithinOnePhase() = runTest {
        val port = FakeDjiPort()
        val events = collect(integration(port).connect(ConnectTarget.Saved(saved, wifi.id)))
        runCurrent()
        port.phaseFlow.value = ConnectionPhase.JOINING_WIFI
        runCurrent()
        assertEquals(1, events.filterIsInstance<ConnectionEvent.Progress>().last().progress.current)
        // The station search starts while the session stays in JOINING_WIFI.
        port.setupProgress.value = "Finding the camera on studio"
        runCurrent()
        val finding = events.filterIsInstance<ConnectionEvent.Progress>().last().progress
        assertEquals(2, finding.current)
        assertEquals("Finding the camera on studio", finding.note)
    }

    @Test
    fun addingARouteSavesTheNetworkFirst() = runTest {
        val port = FakeDjiPort()
        val draft = RouteDraft(RouteKind.PHONE_HOTSPOT, network = "phone", secret = "hunter22")
        val events = collect(integration(port).connect(ConnectTarget.AddRoute(saved, draft)))
        runCurrent()
        assertEquals(listOf(Triple("phone", "hunter22", true)), savedNetworks)
        assertEquals(CameraConnectionSetup.PHONE_HOTSPOT, port.setups.single().first)
        port.phaseFlow.value = ConnectionPhase.LIVE
        runCurrent()
        val record = assertIs<ConnectionEvent.Connected>(events.last()).camera.saved
        assertEquals(listOf("ap", "wifi", "hotspot"), record.routes.map { it.key })
        assertTrue(record.routes.last().network == "phone" && record.preferredRoute == record.routes.last().id)
    }

    @Test
    fun typedFailuresKeepTheirCopy() = runTest {
        val silent = DjiFailures.classify(DatalinkHandshakeException("camera never answered the datalink handshake"), ConnectionPhase.OPENING_DATALINK, "camera never answered the datalink handshake")
        assertTrue(silent.reason == ConnectionFailure.Reason.TimedOut && silent.phase == CorePhase.NEGOTIATING)
        assertEquals("The camera never answered the video link. ${DjiFailures.DJI_APPS_TIP}", silent.message, "the friendly copy with the DJI apps tip")
        val approval = DjiFailures.classify(IllegalStateException("pairing timed out"), ConnectionPhase.AWAITING_APPROVAL, "pairing timed out")
        assertEquals(ConnectionFailure.Reason.NotApproved, approval.reason)
        assertEquals("Turn off DJI Frame Tap and force quit DJI Mimo on every phone near the camera.", DjiFailures.DJI_APPS_TIP)
        assertEquals("The camera didn't respond in time. Check Bluetooth and try again. ${DjiFailures.DJI_APPS_TIP}", approval.message)
        assertEquals("The camera ended the link.", DjiFailures.classify(null, ConnectionPhase.JOINING_WIFI, "the camera ended the link").message)
        assertEquals(DjiFailures.HOTSPOT_OFF, DjiFailures.classify(null, ConnectionPhase.JOINING_WIFI, "no hotspot", hotspotOff = true).message)
        val denied = DjiFailures.classify(SecurityException("no"), ConnectionPhase.SCANNING, "no")
        // Android main's cards offered Try again only (SavedCameraSetupPresentation.failure).
        assertEquals(listOf(RecoveryAction.Retry), denied.actions)
        assertEquals("org.opencapture.openpocketcine.dji.datalink.silent", silent.code)

        val port = FakeDjiPort()
        val events = collect(integration(port).connect(ConnectTarget.Saved(saved, ap.id)))
        runCurrent()
        port.failureDetail.value = approval
        port.phaseFlow.value = ConnectionPhase.FAILED
        runCurrent()
        val failure = assertIs<ConnectionEvent.Failed>(events.last()).failure
        assertTrue(failure == approval, "camera Wi-Fi keeps the session's failure as is")
    }

    @Test
    fun cancellingTheConsumerDisconnects() = runTest {
        val port = FakeDjiPort()
        val job = backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) { integration(port).connect(ConnectTarget.Saved(saved, ap.id)).collect {} }
        runCurrent()
        job.cancel()
        runCurrent()
        assertEquals(1, port.disconnects)
    }

    @Test
    fun aNewerAttemptEndsTheOlder() = runTest {
        val port = FakeDjiPort()
        val dji = integration(port)
        val older = mutableListOf<ConnectionEvent>()
        val olderJob = backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) {
            dji.connect(ConnectTarget.Saved(saved, ap.id)).collect { older += it }
        }
        runCurrent()
        val newer = collect(dji.connect(ConnectTarget.Saved(saved.copy(id = "cam-2"), ap.id)))
        runCurrent()
        port.phaseFlow.value = ConnectionPhase.AWAITING_APPROVAL
        runCurrent()
        port.phaseFlow.value = ConnectionPhase.LIVE
        runCurrent()
        assertTrue(olderJob.isCompleted && older.none { it is ConnectionEvent.Connected || it is ConnectionEvent.Failed }, "the older attempt ends without an outcome")
        assertTrue(older.none { (it as? ConnectionEvent.Progress)?.progress?.phase == CorePhase.AWAITING_APPROVAL })
        assertEquals("cam-2", assertIs<ConnectionEvent.Connected>(newer.last()).camera.saved.id)
        assertEquals(listOf("cam-1", "cam-2"), port.reconnects)
        assertEquals(1, port.disconnects, "the older attempt never disconnects the newer one")
    }

    /** An attempt starts when collected: the consumer replaces one that has not started by cancelling it. */
    @Test
    fun replacingBeforeTheTaskStartsDoesNotConnectTheOldCamera() = runTest {
        val port = FakeDjiPort()
        val dji = integration(port)
        val previous = mutableListOf<ConnectionEvent>()
        backgroundScope.launch { dji.connect(ConnectTarget.Saved(saved, ap.id)).collect { previous += it } }.cancel()
        val replacement = saved.copy(id = "cam-2")
        val events = collect(dji.connect(ConnectTarget.Saved(replacement, ap.id)))
        runCurrent()
        assertEquals(listOf("cam-2"), port.reconnects)
        port.phaseFlow.value = ConnectionPhase.LIVE
        runCurrent()
        assertEquals("cam-2", assertIs<ConnectionEvent.Connected>(events.last()).camera.saved.id)
        assertTrue(previous.isEmpty(), "the replaced attempt never ran")
    }

    @Test
    fun forgetDropsTheSavedWiFiOnly() = runTest {
        integration(FakeDjiPort()).forget(saved)
        assertEquals(listOf("cam-1"), forgotten)
    }

    @Test
    fun aMovingSetupIsRememberedBeforeItMovesTheCamera() = runTest {
        val port = FakeDjiPort()
        val dji = integration(port)
        val stored = mutableListOf<SavedCamera>()
        dji.saveRecord = { stored += it }
        collect(dji.connect(ConnectTarget.Saved(saved, ap.id)))
        runCurrent()
        assertTrue(stored.isEmpty(), "camera Wi-Fi is remembered only once live")
        val overWiFi = collect(dji.connect(ConnectTarget.Saved(saved, wifi.id)))
        runCurrent()
        assertEquals(listOf(wifi.id), stored.map { it.preferredRoute }, "stamped before the attempt starts")
        port.failureDetail.value = DjiFailures.classify(null, ConnectionPhase.JOINING_WIFI, "m")
        port.phaseFlow.value = ConnectionPhase.FAILED
        runCurrent()
        assertIs<ConnectionEvent.Failed>(overWiFi.last())
        assertEquals(1, stored.size, "a failed attempt leaves the stamp in place")

        collect(dji.connect(ConnectTarget.AddRoute(saved, RouteDraft(RouteKind.PHONE_HOTSPOT, network = "phone", secret = "hunter22"))))
        runCurrent()
        assertEquals(listOf("ap", "wifi", "hotspot"), stored.last().routes.map { it.key }, "a route being added is saved first")
        assertEquals(stored.last().routes.last().id, stored.last().preferredRoute)
    }

    @Test
    fun stampingWithoutTheRouteKeepsTheLegacySetup() = runTest {
        val apOnly = saved.copy(routes = listOf(ap))
        val stamped = DjiIntegration.stamping(apOnly, RouteKind.INFRASTRUCTURE_NETWORK)
        assertTrue(stamped.preferredRoute == null && stamped.extras["lastSetup"] == "wifi")
        assertEquals(apOnly, DjiIntegration.stamping(apOnly, RouteKind.CAMERA_ACCESS_POINT))
        val port = FakeDjiPort()
        val events = collect(integration(port).connect(ConnectTarget.Saved(stamped, ap.id)))
        runCurrent()
        assertTrue(port.setups.single().third, "the scan may have left the camera in station role")
        port.phaseFlow.value = ConnectionPhase.LIVE
        runCurrent()
        val record = assertIs<ConnectionEvent.Connected>(events.last()).camera.saved
        assertTrue(record.extras["lastSetup"] == null && record.preferredRoute == ap.id)
    }

    @Test
    fun anotherCamerasNetworkIsNeverSaved() = runTest {
        val port = FakeDjiPort()
        val dji = integration(port)
        dji.savedCameras = { listOf(saved.copy(id = "cam-2")) }
        port.found.value = listOf(FoundCamera("cam-3", "CC", "OsmoPocket3-CCCC", djiBodyProfile("Osmo Pocket 3"), 0x20))
        val owned = collect(dji.connect(ConnectTarget.Nearby(NearbyCamera("cam-3", name = "Osmo Pocket 3", model = "Osmo Pocket 3", routes = setOf(RouteKind.CAMERA_ACCESS_POINT)))))
        runCurrent()
        port.joinedSSID = "OsmoPocket3-AAAA"
        port.phaseFlow.value = ConnectionPhase.LIVE
        runCurrent()
        val first = assertIs<ConnectionEvent.Connected>(owned.last()).camera.saved
        assertEquals(listOf<String?>(null), first.routes.map { it.network }, "the other camera's access point is not saved here")
        assertTrue(first.advertisedName == "OsmoPocket3-CCCC" && first.extras["modelId"] == "32")

        port.found.value = listOf(FoundCamera("cam-4", "DD", "OsmoNano-DDDD", djiBodyProfile("Osmo Nano", family = "nano"), 0x19))
        val crossed = collect(dji.connect(ConnectTarget.Nearby(NearbyCamera("cam-4", name = "Osmo Nano", model = "Osmo Nano", routes = setOf(RouteKind.CAMERA_ACCESS_POINT)))))
        runCurrent()
        port.joinedSSID = "OsmoPocket3-EEEE"
        port.phaseFlow.value = ConnectionPhase.LIVE
        runCurrent()
        val second = assertIs<ConnectionEvent.Connected>(crossed.last()).camera.saved
        assertEquals(listOf<String?>(null), second.routes.map { it.network }, "a Pocket network is never saved with a Nano")
    }

    @Test
    fun aRestoredAccessPointFollowsAMovedCamera() = runTest {
        val port = FakeDjiPort()
        collect(integration(port).connect(ConnectTarget.Saved(saved.copy(preferredRoute = wifi.id), ap.id)))
        runCurrent()
        assertTrue(port.setups.single().third, "the camera may still be in station role")
        assertTrue(ConnectionPrompt.ApproveOnCamera(DjiIntegration.APPROVE).text == "Approve on the camera")
    }
}
