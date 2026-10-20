package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.media.CameraMediaService
import com.opencapture.opencine.media.CameraMediaBrowse
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.ConnectionEvent
import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionPhase as CorePhase
import com.opencapture.opencine.core.ConnectionPrompt
import com.opencapture.opencine.core.DiscoveryMode
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.RouteDraft
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedRoute
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.lunaLike
import com.opencapture.opencine.insta360.shell.CameraIdentity
import com.opencapture.opencine.insta360.shell.ConnectionPhase
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A scripted Luna backend (Swift `FakeLunaPort`): one connect at a time, finished by the test. */
private class FakeLunaPort(private val scope: CoroutineScope) : LunaConnectPort {
    override val phase = MutableStateFlow(ConnectionPhase.IDLE)
    override val found = MutableStateFlow<List<CameraIdentity>>(emptyList())
    override val joinedSSID = MutableStateFlow<String?>(null)
    override val failureDetail = MutableStateFlow<ConnectionFailure?>(null)
    override val scanBlocked = MutableStateFlow(false)
    override var attempt: Job? = null
    var scans = 0
    var scanStops = 0
    val connects = mutableListOf<String>()
    /** Whether the most recent connect started after the camera had advertised. */
    var connectSawSighting: Boolean? = null
    var disconnects = 0
    var makeMediaService: ((CameraSessionID) -> CameraMediaService?)? = null
    val forgotten = mutableListOf<String>()
    val seen = mutableSetOf<String>()
    val savedWiFi = mutableSetOf<String>()
    private var outcome: CompletableDeferred<ConnectionFailure?>? = null

    override fun startScan() { scans += 1 }
    override fun stopScan() { scanStops += 1 }
    override fun hasSeen(id: String): Boolean = id in seen
    override suspend fun hasSavedWiFi(id: String): Boolean = id in savedWiFi
    override fun connect(id: String) {
        connects += id
        connectSawSighting = id in seen
        val done = CompletableDeferred<ConnectionFailure?>()
        outcome = done
        attempt = scope.launch {
            failureDetail.value = null
            val failure = done.await()
            if (failure != null) {
                failureDetail.value = failure
                phase.value = ConnectionPhase.FAILED
            } else {
                phase.value = ConnectionPhase.LIVE
                awaitCancellation()
            }
        }
    }
    fun goLive() { outcome?.complete(null) }
    fun fail(failure: ConnectionFailure) { outcome?.complete(failure) }
    override fun disconnect() {
        disconnects += 1
        attempt?.cancel()
        phase.value = ConnectionPhase.IDLE
    }
    override fun openSession(): CameraSession = FakeCameraSession.lunaLike()
    override fun mediaService(session: CameraSessionID): CameraMediaService? = makeMediaService?.invoke(session)
    override suspend fun forget(id: String) { forgotten += id }
}

/** Swift suite `LunaIntegrationTests`, same method names. */
@OptIn(ExperimentalCoroutinesApi::class)
class LunaIntegrationTest {
    private val camera = "AA:BB:CC:DD:EE:01"
    private val sighting = NearbyCamera(camera, name = "Luna 1A2B", model = "Insta360 Luna Ultra", routes = setOf(RouteKind.CAMERA_ACCESS_POINT))

    private fun TestScope.setup(): Pair<FakeLunaPort, LunaIntegration> {
        val port = FakeLunaPort(backgroundScope)
        return port to LunaIntegration(port, now = { 1_759_307_200_000 })
    }

    private fun TestScope.collect(events: Flow<ConnectionEvent>): MutableList<ConnectionEvent> {
        val seen = mutableListOf<ConnectionEvent>()
        backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) { events.collect { seen += it } }
        return seen
    }

    @Test fun actualConnectionRegistersMediaByProtocolTypeAndRejectsWrongSession() = runTest {
        for (matching in listOf(true, false)) {
            val (port, luna) = setup()
            port.makeMediaService = { session -> object : CameraMediaService {
                override val sessionID = if (matching) session else CameraSessionID()
                override suspend fun openBrowse(): CameraMediaBrowse = error("No browse requested")
            } }
            val events = collect(luna.connect(ConnectTarget.Nearby(sighting)))
            runCurrent(); port.goLive(); runCurrent()
            val camera = assertIs<ConnectionEvent.Connected>(events.last()).camera
            assertEquals(matching, camera.services.get<CameraMediaService>() != null)
            port.disconnect()
        }
    }

    /** II-202: the baseline scanned for a few seconds and connected over Bluetooth when the camera
     * advertised; only then did it dial saved Wi-Fi. The shared model dialled saved Wi-Fi at once. */
    @Test
    fun aSavedReconnectWaitsForTheBluetoothAdvertBeforeSavedWiFi() = runTest {
        val port = FakeLunaPort(backgroundScope)
        val luna = LunaIntegration(port, now = { testScheduler.currentTime })
        port.savedWiFi += camera
        val ap = SavedRoute(key = "ap", kind = RouteKind.CAMERA_ACCESS_POINT, network = "LUNA-1A2B", bluetooth = true)
        val saved = SavedCamera(
            id = camera, integration = luna.id, advertisedName = "Luna 1A2B", model = "Insta360 Luna Ultra",
            routes = listOf(ap), preferredRoute = ap.id,
        )
        val events = collect(luna.connect(ConnectTarget.Saved(saved, ap.id)))
        runCurrent()
        // The grace is running: no Wi-Fi dial yet, and the card says it is looking.
        assertEquals(0, port.connects.size)
        assertTrue(port.scans >= 1)
        assertTrue(events.filterIsInstance<ConnectionEvent.Progress>().any { it.progress.note == "Looking for the camera" })
        // The camera now advertises: Bluetooth is the route the backend takes.
        port.seen += camera
        port.found.value = listOf(CameraIdentity(camera, "Luna 1A2B", "Insta360 Luna Ultra"))
        advanceTimeBy(LunaIntegration.SIGHTING_STEP_MS)
        runCurrent()
        assertEquals(listOf(camera), port.connects)
        assertEquals(true, port.connectSawSighting, "the advert chose the Bluetooth bootstrap")
        val phases = events.filterIsInstance<ConnectionEvent.Progress>().map { it.progress.phase }
        assertTrue(CorePhase.JOINING_NETWORK !in phases, "saved Wi-Fi is not dialled before the advert")
    }

    private fun TestScope.savedGrace(): Pair<FakeLunaPort, Pair<LunaIntegration, ConnectTarget>> {
        val port = FakeLunaPort(backgroundScope)
        val luna = LunaIntegration(port, now = { testScheduler.currentTime })
        port.savedWiFi += camera
        val ap = SavedRoute(key = "ap", kind = RouteKind.CAMERA_ACCESS_POINT, network = "LUNA-1A2B", bluetooth = true)
        val saved = SavedCamera(
            id = camera, integration = luna.id, advertisedName = "Luna 1A2B", model = "Insta360 Luna Ultra",
            routes = listOf(ap), preferredRoute = ap.id,
        )
        return port to (luna to ConnectTarget.Saved(saved, ap.id))
    }

    @Test
    fun aCancelledSightingGraceStopsTheScanItStarted() = runTest {
        val (port, pair) = savedGrace()
        val (luna, target) = pair
        val attempt = backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) { luna.connect(target).collect {} }
        runCurrent()
        assertEquals(1, port.scans); assertEquals(0, port.connects.size)
        attempt.cancel(); runCurrent()
        assertEquals(1, port.scanStops, "a cancelled grace must not leave the Bluetooth scan running")
    }

    @Test
    fun theSightingGraceKeepsTheScanWhenTheLastListenerLeaves() = runTest {
        val (port, pair) = savedGrace()
        val (luna, target) = pair
        val listening = backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) { luna.discover(DiscoveryMode.PASSIVE).collect {} }
        backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) { luna.connect(target).collect {} }
        runCurrent()
        listening.cancel(); runCurrent()
        assertEquals(0, port.scanStops, "the grace still needs the scan after the last listener leaves")
    }

    @Test
    fun discoveryListensPassivelyOverBluetooth() = runTest {
        val (port, luna) = setup()
        assertEquals(setOf(DiscoveryMode.PASSIVE), luna.discoveryModes)
        assertTrue(luna.discover(DiscoveryMode.ACTIVE).toList().isEmpty())
        val lists = mutableListOf<List<NearbyCamera>>()
        val job = backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) { luna.discover(DiscoveryMode.PASSIVE).collect { lists += it } }
        port.found.value = listOf(CameraIdentity(camera, "Luna 1A2B", "Insta360 Luna Ultra"))
        runCurrent()
        assertEquals(listOf(emptyList(), listOf(sighting)), lists)
        assertTrue(port.scans == 1 && port.connects.isEmpty(), "listening never connects")
        job.cancel()
        runCurrent()
        assertEquals(1, port.scanStops)
    }

    @Test
    fun discoveryRunningFollowsTheScanNotAFailedConnect() = runTest {
        val (port, luna) = setup()
        val running = mutableListOf<Boolean>()
        backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) { luna.discoveryRunning.collect { running += it } }
        collect(luna.connect(ConnectTarget.Nearby(sighting)))
        runCurrent(); port.fail(LunaFailures.connect(ConnectionPhase.CONNECTING_GATT)); runCurrent()
        assertEquals(listOf(true), running, "a failed connect leaves the scan running")
        port.scanBlocked.value = true; runCurrent()
        assertEquals(listOf(true, false), running, "a blocked scan stops the scanning status")
        port.scanBlocked.value = false; runCurrent()
        assertEquals(listOf(true, false, true), running)
    }

    @Test
    fun phasesMapToProgressAndPrompts() = runTest {
        val (port, luna) = setup()
        val events = collect(luna.connect(ConnectTarget.Nearby(sighting)))
        runCurrent()
        for (phase in listOf(ConnectionPhase.CONNECTING_GATT, ConnectionPhase.AWAITING_APPROVAL, ConnectionPhase.JOINING_WIFI, ConnectionPhase.OPENING_DATALINK)) {
            if (phase == ConnectionPhase.JOINING_WIFI) port.joinedSSID.value = "LUNA-1A2B"
            port.phase.value = phase
            runCurrent()
        }
        port.goLive()
        runCurrent()
        val progress = events.filterIsInstance<ConnectionEvent.Progress>()
        assertTrue(progress.all { it.progress.steps == LunaIntegration.STEPS })
        // The Wi-Fi step reads its phase (main's caption).
        assertEquals(
            listOf("NEGOTIATING 0 - -", "AWAITING_APPROVAL 0 approve: Approve on the camera -",
                "JOINING_NETWORK 1 - Joining camera Wi-Fi…", "LINK 2 - -"),
            progress.map { "${it.progress.phase} ${it.progress.current} ${it.prompt?.let(::describe) ?: "-"} ${it.progress.note ?: "-"}" },
        )
        val saved = assertIs<ConnectionEvent.Connected>(events.last()).camera.saved
        assertTrue(saved.id == camera && saved.integration == luna.id && saved.lastConnected == 1_759_307_200_000)
        assertEquals(listOf(RouteKind.CAMERA_ACCESS_POINT), saved.routes.map { it.kind })
        assertTrue(saved.routes[0].network == "LUNA-1A2B" && saved.routes[0].bluetooth && saved.preferredRoute == saved.routes[0].id)
        assertNull(saved.device, "Android reads no serial")
    }

    @Test
    fun aSavedCameraKeepsItsRecord() = runTest {
        val (port, luna) = setup()
        val ap = SavedRoute(key = "ap", kind = RouteKind.CAMERA_ACCESS_POINT, network = "LUNA-OLD", bluetooth = true)
        val saved = SavedCamera(
            id = camera, integration = luna.id, name = "A cam", advertisedName = "Luna 1A2B", model = "Insta360 Luna Ultra",
            routes = listOf(ap), extras = mapOf("lastSetup" to "wifi"),
        )
        val events = collect(luna.connect(ConnectTarget.Saved(saved, ap.id)))
        runCurrent()
        assertEquals(listOf(camera), port.connects)
        port.goLive()
        runCurrent()
        val record = assertIs<ConnectionEvent.Connected>(events.last()).camera.saved
        assertTrue(record.name == "A cam" && record.routes == listOf(ap) && record.extras == mapOf("lastSetup" to "wifi"))
    }

    /** A legacy hotspot setup (main's records could carry one) is no dead chip: Luna dials the
     *  camera over its own Wi-Fi, keeps the setup, and makes the camera Wi-Fi preferred again. */
    @Test
    fun aLegacyHotspotSetupConnectsOverCameraWiFi() = runTest {
        val (port, luna) = setup()
        val ap = SavedRoute(key = "ap", kind = RouteKind.CAMERA_ACCESS_POINT, network = "LUNA-1A2B", bluetooth = true)
        val hotspot = SavedRoute(key = "hotspot", kind = RouteKind.PHONE_HOTSPOT, network = "Rig iPhone")
        val saved = SavedCamera(
            id = camera, integration = luna.id, advertisedName = "Luna 1A2B", model = "Insta360 Luna Ultra",
            routes = listOf(ap, hotspot), preferredRoute = hotspot.id,
        )
        val events = collect(luna.connect(ConnectTarget.Saved(saved, hotspot.id)))
        runCurrent()
        assertEquals(listOf(camera), port.connects)
        port.goLive()
        runCurrent()
        val record = assertIs<ConnectionEvent.Connected>(events.last()).camera.saved
        assertTrue(record.routes == listOf(ap, hotspot) && record.preferredRoute == ap.id)
    }

    @Test
    fun typedFailuresKeepTheirCopy() = runTest {
        // The backend's copy, now typed at the site that chooses it.
        val copy = mapOf(
            ConnectionPhase.AWAITING_APPROVAL to "Camera approval was not completed. Wake Luna and accept the connection on its screen.",
            ConnectionPhase.JOINING_WIFI to "Could not join Luna Wi-Fi. Keep the camera awake and accept Android's Wi-Fi connection request.",
            ConnectionPhase.LIVE to "The camera feed disconnected. Wake Luna and tap Retry.",
            ConnectionPhase.OPENING_DATALINK to "The camera Wi-Fi connected, but live view did not start. Close the Insta360 app and try again.",
            ConnectionPhase.CONNECTING_GATT to "Could not connect to Luna. Keep it awake, close the Insta360 app, and try again.",
        )
        for ((phase, message) in copy) assertEquals(message, LunaFailures.connect(phase).message)
        assertEquals(ConnectionFailure.Reason.NotApproved, LunaFailures.connect(ConnectionPhase.AWAITING_APPROVAL).reason)
        assertEquals(ConnectionFailure.Reason.JoinFailed, LunaFailures.connect(ConnectionPhase.JOINING_WIFI).reason)
        assertEquals("com.opencapture.insta360.luna.approval.incomplete", LunaFailures.connect(ConnectionPhase.AWAITING_APPROVAL).code)
        // Device cell 7d: a camera that is off is named as missing, not as a busy camera.
        val missing = LunaFailures.connect(ConnectionPhase.CONNECTING_GATT, advertising = false)
        assertEquals(ConnectionFailure.Reason.NotFound, missing.reason)
        assertEquals("The camera did not answer. Make sure it is turned on and nearby, then try again.", missing.message)
        assertEquals("com.opencapture.insta360.luna.bluetooth.camera-missing", missing.code)
        assertEquals(ConnectionFailure.Reason.Other, LunaFailures.connect(ConnectionPhase.CONNECTING_GATT, advertising = true).reason)
        assertEquals("Allow Nearby devices and location access to discover your camera.", LunaFailures.discoveryDenied.message)
        assertEquals(listOf(RecoveryAction.OpenSettings, RecoveryAction.Retry), LunaFailures.discoveryDenied.actions)
        assertEquals("Bluetooth scanning could not start (2). Check Nearby devices permission.", LunaFailures.scanFailed(2).message)

        val (port, luna) = setup()
        val events = collect(luna.connect(ConnectTarget.Nearby(sighting)))
        runCurrent()
        port.phase.value = ConnectionPhase.AWAITING_APPROVAL
        runCurrent()
        port.fail(LunaFailures.connect(ConnectionPhase.AWAITING_APPROVAL))
        runCurrent()
        val failure = assertIs<ConnectionEvent.Failed>(events.last()).failure
        assertTrue(failure.reason == ConnectionFailure.Reason.NotApproved && failure.phase == CorePhase.AWAITING_APPROVAL)
    }

    @Test
    fun aNewerAttemptEndsTheOlder() = runTest {
        val (port, luna) = setup()
        val a = collect(luna.connect(ConnectTarget.Nearby(sighting)))
        runCurrent()
        val b = collect(luna.connect(ConnectTarget.Nearby(sighting)))
        runCurrent()
        port.phase.value = ConnectionPhase.AWAITING_APPROVAL
        runCurrent()
        port.goLive()
        runCurrent()
        assertTrue(a.none { it is ConnectionEvent.Connected || it is ConnectionEvent.Failed }, "the older attempt ends without an outcome")
        assertTrue(a.none { (it as? ConnectionEvent.Progress)?.progress?.phase == CorePhase.AWAITING_APPROVAL })
        assertIs<ConnectionEvent.Connected>(b.last())
        assertEquals(2, port.connects.size)
    }

    /** An attempt starts when collected: the consumer replaces one that has not started by cancelling it. */
    @Test
    fun replacingBeforeTheTaskStartsDoesNotConnectTheOldCamera() = runTest {
        val (port, luna) = setup()
        val previous = mutableListOf<ConnectionEvent>()
        backgroundScope.launch { luna.connect(ConnectTarget.Nearby(sighting)).collect { previous += it } }.cancel()
        val replacement = sighting.copy(id = "AA:BB:CC:DD:EE:02")
        val events = collect(luna.connect(ConnectTarget.Nearby(replacement)))
        runCurrent()
        assertEquals(listOf(replacement.id), port.connects)
        port.goLive()
        runCurrent()
        assertEquals(replacement.id, assertIs<ConnectionEvent.Connected>(events.last()).camera.saved.id)
        assertTrue(previous.isEmpty(), "the replaced attempt never ran")
    }

    @Test
    fun cancellingTheConsumerDisconnects() = runTest {
        val (port, luna) = setup()
        val job = backgroundScope.launch(start = CoroutineStart.UNDISPATCHED) { luna.connect(ConnectTarget.Nearby(sighting)).collect {} }
        runCurrent()
        val before = port.disconnects
        job.cancel()
        runCurrent()
        assertEquals(before + 1, port.disconnects)
    }

    @Test
    fun forgetDropsTheSavedWiFiOnly() = runTest {
        val (port, luna) = setup()
        luna.forget(SavedCamera(id = camera, integration = luna.id, advertisedName = "", model = ""))
        assertEquals(listOf(camera), port.forgotten)
    }

    @Test
    fun addingARouteIsUnsupported() = runTest {
        val (port, luna) = setup()
        val saved = SavedCamera(id = camera, integration = luna.id, advertisedName = "", model = "")
        val events = luna.connect(ConnectTarget.AddRoute(saved, RouteDraft(RouteKind.INFRASTRUCTURE_NETWORK))).toList()
        assertEquals(ConnectionFailure.Reason.Unsupported, assertIs<ConnectionEvent.Failed>(events.single()).failure.reason)
        assertTrue(port.connects.isEmpty())
    }

    private fun describe(prompt: ConnectionPrompt): String = when (prompt) {
        is ConnectionPrompt.ApproveOnCamera -> "approve: ${prompt.text}"
        is ConnectionPrompt.AcceptNetworkJoin -> "join ${prompt.network}: ${prompt.text}"
        is ConnectionPrompt.Integration -> "integration: ${prompt.text}"
    }
}
