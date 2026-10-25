package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.ConnectionEvent
import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionPhase
import com.opencapture.opencine.core.ConnectionPrompt
import com.opencapture.opencine.core.DiscoveryMode
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.UnavailableReason
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.nikonLike
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.json.JSONArray
import org.json.JSONObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

/** A scripted Nikon pipeline (Swift `FakeNikonPort`): it records discovery modes, connects, cancels and forgets. */
private class FakeNikonPort : NikonConnectPort {
    override val sightings = MutableStateFlow<List<NikonSighting>>(emptyList())
    override val phase = MutableStateFlow<Pair<NikonConnectionPhase, String?>?>(null)
    var records: String? = null
    val discovery = mutableListOf<DiscoveryMode?>()
    val connects = mutableListOf<NikonConnectRequest>()
    val consentedRequests = mutableListOf<NikonConnectRequest>()
    var cancels = 0
    val forgotten = mutableListOf<List<String>>()
    var pending = CompletableDeferred<NikonConnection>()

    override fun savedRecords(): String? = records
    override fun startDiscovery(mode: DiscoveryMode) { discovery += mode }
    override fun stopDiscovery() { discovery += null }
    override suspend fun connect(request: NikonConnectRequest): NikonConnection {
        connects += request
        pending = CompletableDeferred()
        return pending.await()
    }
    override suspend fun connect(request: NikonConnectRequest, takingOverConfirmed: Boolean): NikonConnection {
        if (takingOverConfirmed) consentedRequests += request
        return connect(request)
    }
    override fun cancel() { cancels++ }
    override fun forget(hosts: List<String>) { forgotten += hosts }

    /** The presence lookup's answer, and every host it was asked about. */
    var holder: String? = null
    val holderQueries = mutableListOf<String>()
    override suspend fun currentHolder(host: String): String? {
        holderQueries += host
        return holder
    }
}

/** Swift suite `NikonIntegrationTests`, same method names, against a scripted pipeline. */
@OptIn(ExperimentalCoroutinesApi::class)
class NikonIntegrationTest {
    private val port = FakeNikonPort().apply {
        records = JSONArray()
            .put(record("192.168.1.1", "camera-access-point", 1_000).put("wifi-ssid", "NIKON_ZR_3001234"))
            .put(record("192.168.50.23", "infrastructure", 61_000).put("network-name", "Studio"))
            .put(JSONObject().put("host", "192.168.43.20").put("camera-name", "ZR_4005678").put("transport", "phone-hotspot").put("last-seen-at", 1_000).put("profile-id", "192.168.43.20"))
            .toString()
    }
    private val nikon = NikonIntegration(port)

    private fun record(host: String, transport: String, seen: Long) =
        JSONObject().put("host", host).put("camera-name", "ZR_3001234").put("transport", transport).put("last-seen-at", seen).put("profile-id", host)

    private fun cameras() = NikonSavedRecordsV0().cameras(port.records!!)!!.map { it.camera }

    /** The passive-only rule at the integration: only a pairing listener ever turns discovery active. */
    @Test
    fun theCamerasListNeverAsksForActiveDiscovery() = runTest {
        val passive = backgroundScope.launch { nikon.discover(DiscoveryMode.PASSIVE).collect {} }
        runCurrent()
        assertEquals(listOf<DiscoveryMode?>(DiscoveryMode.PASSIVE), port.discovery)
        val pairing = backgroundScope.launch { nikon.discover(DiscoveryMode.ACTIVE).collect {} }
        runCurrent()
        assertEquals(listOf<DiscoveryMode?>(DiscoveryMode.PASSIVE, DiscoveryMode.ACTIVE), port.discovery)
        pairing.cancel()
        runCurrent()
        assertEquals(listOf<DiscoveryMode?>(DiscoveryMode.PASSIVE, DiscoveryMode.ACTIVE, DiscoveryMode.PASSIVE), port.discovery)
        passive.cancel()
        runCurrent()
        assertEquals(listOf(DiscoveryMode.PASSIVE, DiscoveryMode.ACTIVE, DiscoveryMode.PASSIVE, null), port.discovery)
        assertTrue(port.connects.isEmpty(), "discovering never connects")
    }

    @Test
    fun sightingsNameTheSetupTheyReach() = runTest {
        port.records = JSONArray(port.records).put(record("usb:zr", "usb-c", 2_000)).toString()
        port.sightings.value = listOf(
            // Its Studio setup's address; the access point's (no proof off its network); a cable; elsewhere.
            NikonSighting("192.168.50.23", null, NikonSighting.Source.LIVENESS),
            NikonSighting("192.168.1.1", "ZR_3001234", NikonSighting.Source.NETWORK),
            NikonSighting("usb:77", "ZR_3001234", NikonSighting.Source.USB),
            NikonSighting("10.1.1.7", "ZR_3001234", NikonSighting.Source.NETWORK),
        )
        val list = nikon.discover(DiscoveryMode.PASSIVE).first()
        assertEquals(List(4) { "name:zr_3001234" }, list.map { it.savedID })
        assertEquals(listOf("192.168.50.23|infrastructure", null, "usb:zr|usb-c", null), list.map { it.routeKey })
    }

    @Test
    fun sightingsNameTheirSavedCamera() = runTest {
        port.sightings.value = listOf(
            NikonSighting("192.168.50.23", null, NikonSighting.Source.LIVENESS),
            NikonSighting("192.168.50.99", null, NikonSighting.Source.LIVENESS),
            NikonSighting("192.168.50.40", "Z_8_7000001", NikonSighting.Source.NETWORK),
            NikonSighting("192.168.50.41", null, NikonSighting.Source.HELD_BY_ANOTHER_DEVICE, heldBy = "Phone B"),
            NikonSighting("usb:99", "Z_6_3_8000001", NikonSighting.Source.USB),
        )
        val list = nikon.discover(DiscoveryMode.PASSIVE).first()
        assertEquals(listOf("192.168.50.23", "192.168.50.40", "192.168.50.41", "usb:99"), list.map { it.id })
        assertEquals(listOf("name:zr_3001234", null, null, null), list.map { it.savedID })
        assertEquals(
            listOf(Availability.Available, Availability.Available, Availability.Unavailable(UnavailableReason.Busy), Availability.Available),
            list.map { it.availability },
        )
        assertEquals(listOf(RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.USB), list.map { it.routes.single() })
    }

    @Test
    fun connectedServicesPreserveExactInstanceAndDefaultEmpty() = runTest {
        val camera = cameras().first()
        val route = camera.routes.first { it.kind == RouteKind.INFRASTRUCTURE_NETWORK }
        val native = FakeCameraSession.nikonLike()
        val marker = object : com.opencapture.opencine.media.CameraMediaService {
            override val sessionID = native.id
            override suspend fun openBrowse(): com.opencapture.opencine.media.CameraMediaBrowse =
                throw com.opencapture.opencine.media.MediaServiceException(com.opencapture.opencine.media.MediaServiceFailure.UNAVAILABLE)
        }
        val services = com.opencapture.opencine.core.CameraServices().plus(com.opencapture.opencine.media.CameraMediaService::class, marker)
        kotlin.test.assertNull(NikonConnection(native, "192.168.50.23", RouteKind.INFRASTRUCTURE_NETWORK).services.get<com.opencapture.opencine.media.CameraMediaService>())
        val events = mutableListOf<ConnectionEvent>()
        val job = backgroundScope.launch { nikon.connect(ConnectTarget.Saved(camera, route.id)).toList(events) }
        runCurrent()
        port.pending.complete(NikonConnection(native, "192.168.50.23", RouteKind.INFRASTRUCTURE_NETWORK, services))
        job.join()
        val connected = assertIs<ConnectionEvent.Connected>(events.last()).camera
        kotlin.test.assertSame(marker, connected.services.get<com.opencapture.opencine.media.CameraMediaService>())
        assertEquals(native.id, connected.session.id)
    }

    @Test
    fun aSavedSetupConnectsThroughTheAppFunnel() = runTest {
        val camera = cameras().first()
        val studio = camera.routes.first { it.kind == RouteKind.INFRASTRUCTURE_NETWORK }
        val events = mutableListOf<ConnectionEvent>()
        val job = backgroundScope.launch { nikon.connect(ConnectTarget.Saved(camera, studio.id)).toList(events) }
        runCurrent()
        assertEquals(listOf<NikonConnectRequest>(NikonConnectRequest.Saved("192.168.50.23", RouteKind.INFRASTRUCTURE_NETWORK)), port.connects)
        for (phase in listOf(NikonConnectionPhase.DISCOVERING, NikonConnectionPhase.HANDSHAKING, NikonConnectionPhase.PREPARING_LIVE_VIEW)) {
            port.phase.value = phase to null
            runCurrent()
        }
        port.pending.complete(NikonConnection(FakeCameraSession.nikonLike(), "192.168.50.23", RouteKind.INFRASTRUCTURE_NETWORK))
        job.join()
        val progress = events.filterIsInstance<ConnectionEvent.Progress>()
        assertEquals(listOf("LINK 0", "NEGOTIATING 1", "NEGOTIATING 2"), progress.map { "${it.progress.phase} ${it.progress.current}" })
        assertEquals(listOf("Finding the camera", "Connecting", "Starting live view"), progress[0].progress.steps.map { it.title })
        assertTrue(progress.all { it.prompt == null })
        val connected = assertIs<ConnectionEvent.Connected>(events.last()).camera.saved
        assertEquals("name:zr_3001234", connected.id)
        assertEquals(camera.routes.map { it.id }, connected.routes.map { it.id }, "route ids survive the read-back")
        assertEquals(studio.id, connected.preferredRoute)
    }

    @Test
    fun theAccessPointAsksToJoinAndThePairingAsksTheCamera() = runTest {
        val camera = cameras().first()
        val ap = camera.routes.first { it.kind == RouteKind.CAMERA_ACCESS_POINT }
        val events = mutableListOf<ConnectionEvent>()
        val job = backgroundScope.launch { nikon.connect(ConnectTarget.Saved(camera, ap.id)).toList(events) }
        runCurrent()
        assertEquals(listOf<NikonConnectRequest>(NikonConnectRequest.Saved("192.168.1.1", RouteKind.CAMERA_ACCESS_POINT)), port.connects)
        for (value in listOf(
            NikonConnectionPhase.JOINING_WIFI to "Approve the network request",
            NikonConnectionPhase.DISCOVERING to null,
            NikonConnectionPhase.PAIRING to "Pairing with code 1234…",
        )) {
            port.phase.value = value
            runCurrent()
        }
        port.pending.completeExceptionally(
            NikonConnectException(NikonIntegration.failure(ConnectionFailure.Reason.NotApproved, "pairing.rejected", "Pairing was rejected.")),
        )
        job.join()
        val progress = events.filterIsInstance<ConnectionEvent.Progress>()
        assertEquals(listOf(0, 1, 1), progress.map { it.progress.current })
        assertEquals("Joining the camera’s Wi-Fi", progress[0].progress.steps.first().title)
        assertEquals(listOf("Approve the network request", null, "Pairing with code 1234…"), progress.map { it.prompt?.text })
        assertIs<ConnectionPrompt.AcceptNetworkJoin>(progress[0].prompt)
        assertEquals(ConnectionPhase.AWAITING_APPROVAL, progress[2].progress.phase)
        val failure = assertIs<ConnectionEvent.Failed>(events.last()).failure
        assertEquals(ConnectionFailure.Reason.NotApproved, failure.reason)
    }

    @Test
    fun aHeldCameraAsksBeforeTakingOver() = runTest {
        val held = NikonSighting("192.168.50.41", "Z_8_7000001", NikonSighting.Source.HELD_BY_ANOTHER_DEVICE, heldBy = "Phone B")
        port.sightings.value = listOf(held)
        val nearby = NearbyCamera(held.host, name = held.displayName, model = "", routes = setOf(RouteKind.INFRASTRUCTURE_NETWORK))
        val events = mutableListOf<ConnectionEvent>()
        backgroundScope.launch { nikon.connect(ConnectTarget.Nearby(nearby)).toList(events) }
        runCurrent()
        val prompt = assertIs<ConnectionPrompt.Integration>(assertIs<ConnectionEvent.Progress>(events.single()).prompt).prompt
        val takeOver = assertIs<NikonTakeOverPrompt>(prompt)
        assertEquals("Phone B is using this camera. Connecting will disconnect it.", takeOver.fallbackText)
        assertTrue(port.connects.isEmpty(), "nothing dials a held camera before the operator agrees")
        takeOver.confirm()
        runCurrent()
        assertEquals(listOf<NikonConnectRequest>(NikonConnectRequest.Discovered(held, takeOver = true)), port.connects)

        // Declining ends the attempt without a connect.
        val declined = mutableListOf<ConnectionEvent>()
        val job = backgroundScope.launch { nikon.connect(ConnectTarget.Nearby(nearby)).toList(declined) }
        runCurrent()
        val second = assertIs<NikonTakeOverPrompt>(assertIs<ConnectionPrompt.Integration>(assertIs<ConnectionEvent.Progress>(declined.single()).prompt).prompt)
        second.cancel()
        job.join()
        assertEquals(1, declined.size)
        assertEquals(1, port.connects.size)
    }

    /**
     * physical-C C9 (2026-10-19): a ZR never refuses a second initiator, it hands the session over
     * and drops the phone holding it, so the saved connect must ask before its first dial.
     */
    @Test
    fun aSavedSetupAnotherDeviceHoldsAsksBeforeDialing() = runTest {
        port.holder = "Phone B"
        val camera = cameras().first()
        val route = camera.routes.first { it.kind == RouteKind.INFRASTRUCTURE_NETWORK }
        val events = mutableListOf<ConnectionEvent>()
        backgroundScope.launch { nikon.connect(ConnectTarget.Saved(camera, route.id)).toList(events) }
        runCurrent()
        val progress = assertIs<ConnectionEvent.Progress>(events.single())
        val prompt = assertIs<NikonTakeOverPrompt>(assertIs<ConnectionPrompt.Integration>(progress.prompt).prompt)
        assertEquals(listOf("192.168.50.23"), port.holderQueries)
        assertEquals("Phone B", prompt.holder)
        assertTrue(port.connects.isEmpty(), "nothing dials the camera before the operator agrees")
        prompt.confirm()
        runCurrent()
        assertEquals(listOf<NikonConnectRequest>(NikonConnectRequest.Saved("192.168.50.23", RouteKind.INFRASTRUCTURE_NETWORK)), port.consentedRequests)
        assertEquals(1, port.connects.size)
    }

    @Test
    fun cancellingTheSavedTakeOverLeavesTheHolderAlone() = runTest {
        port.holder = ""
        val camera = cameras().first()
        val route = camera.routes.first { it.kind == RouteKind.INFRASTRUCTURE_NETWORK }
        val events = mutableListOf<ConnectionEvent>()
        val job = backgroundScope.launch { nikon.connect(ConnectTarget.Saved(camera, route.id)).toList(events) }
        runCurrent()
        val progress = assertIs<ConnectionEvent.Progress>(events.single())
        val prompt = assertIs<NikonTakeOverPrompt>(assertIs<ConnectionPrompt.Integration>(progress.prompt).prompt)
        assertEquals(null, prompt.holder)
        prompt.cancel()
        job.join()
        assertTrue(port.connects.isEmpty() && port.consentedRequests.isEmpty(), "Cancel never dials")
    }

    @Test
    fun aSavedSetupNobodyHoldsDialsWithoutAsking() = runTest {
        val camera = cameras().first()
        val route = camera.routes.first { it.kind == RouteKind.INFRASTRUCTURE_NETWORK }
        backgroundScope.launch { nikon.connect(ConnectTarget.Saved(camera, route.id)).toList(mutableListOf()) }
        runCurrent()
        assertEquals(listOf("192.168.50.23"), port.holderQueries)
        assertEquals(1, port.connects.size)
        assertTrue(port.consentedRequests.isEmpty())
    }

    @Test
    fun aHeldSavedSetupUsesTheSameConsentPrompt() = runTest {
        val camera = cameras().first()
        val route = camera.routes.first { it.kind == RouteKind.INFRASTRUCTURE_NETWORK }
        val events = mutableListOf<ConnectionEvent>()
        val job = backgroundScope.launch { nikon.connect(ConnectTarget.Saved(camera, route.id)).toList(events) }
        runCurrent()
        assertEquals(1, port.connects.size)
        port.pending.completeExceptionally(NikonConnectException(ConnectionFailure(
            reason = ConnectionFailure.Reason.HeldElsewhere, title = "Camera in use",
            message = "Phone B is using this camera. Connecting will disconnect it.",
            actions = listOf(RecoveryAction.Retry), code = "SIMULATED.held",
        )))
        runCurrent()
        val progress = assertIs<ConnectionEvent.Progress>(events.single())
        val prompt = assertIs<NikonTakeOverPrompt>(assertIs<ConnectionPrompt.Integration>(progress.prompt).prompt)
        assertEquals("Phone B is using this camera. Connecting will disconnect it.", prompt.fallbackText)
        assertEquals(1, port.connects.size, "the held attempt cannot retry until the operator agrees")
        prompt.cancel()
        job.join()
        assertEquals(1, port.connects.size, "declining never retries")
    }

    @Test
    fun savedConsentIsOnceOnlyAndAConfirmedFailureCannotAskAgain() = runTest {
        val camera = cameras().first()
        val route = camera.routes.first { it.kind == RouteKind.INFRASTRUCTURE_NETWORK }
        val events = mutableListOf<ConnectionEvent>()
        val job = backgroundScope.launch { nikon.connect(ConnectTarget.Saved(camera, route.id)).toList(events) }
        runCurrent()
        val held = ConnectionFailure(
            reason = ConnectionFailure.Reason.HeldElsewhere, title = "Camera in use", message = "Consent required",
            actions = listOf(RecoveryAction.Retry), code = "SIMULATED.held",
        )
        port.pending.completeExceptionally(NikonConnectException(held))
        runCurrent()
        val prompt = assertIs<NikonTakeOverPrompt>(assertIs<ConnectionPrompt.Integration>(assertIs<ConnectionEvent.Progress>(events.single()).prompt).prompt)
        prompt.confirm()
        prompt.confirm()
        runCurrent()
        assertEquals(2, port.connects.size)
        assertEquals(listOf<NikonConnectRequest>(NikonConnectRequest.Saved("192.168.50.23", RouteKind.INFRASTRUCTURE_NETWORK)), port.consentedRequests)
        port.pending.completeExceptionally(NikonConnectException(held))
        job.join()
        assertEquals(ConnectionFailure.Reason.HeldElsewhere, assertIs<ConnectionEvent.Failed>(events.last()).failure.reason)
        assertEquals(1, events.filterIsInstance<ConnectionEvent.Progress>().size)
        prompt.confirm()
        runCurrent()
        assertEquals(2, port.connects.size)
    }

    @Test
    fun cancellingASavedAttemptRetiresItsUnansweredConsent() = runTest {
        val camera = cameras().first()
        val route = camera.routes.first { it.kind == RouteKind.INFRASTRUCTURE_NETWORK }
        val events = mutableListOf<ConnectionEvent>()
        val job = backgroundScope.launch { nikon.connect(ConnectTarget.Saved(camera, route.id)).toList(events) }
        runCurrent()
        port.pending.completeExceptionally(NikonConnectException(ConnectionFailure(
            reason = ConnectionFailure.Reason.HeldElsewhere, title = "Camera in use", message = "Consent required",
            actions = listOf(RecoveryAction.Retry), code = "SIMULATED.held",
        )))
        runCurrent()
        val prompt = assertIs<NikonTakeOverPrompt>(assertIs<ConnectionPrompt.Integration>(assertIs<ConnectionEvent.Progress>(events.single()).prompt).prompt)
        job.cancel()
        job.join()
        prompt.confirm()
        runCurrent()
        assertTrue(port.consentedRequests.isEmpty())
        assertEquals(1, port.connects.size)
    }

    @Test fun replacingASavedAttemptRetiresItsUnansweredConsent() = runTest {
        val camera = cameras().first()
        val route = camera.routes.first { it.kind == RouteKind.INFRASTRUCTURE_NETWORK }
        val events = mutableListOf<ConnectionEvent>()
        val first = backgroundScope.launch { nikon.connect(ConnectTarget.Saved(camera, route.id)).toList(events) }
        runCurrent()
        port.pending.completeExceptionally(NikonConnectException(ConnectionFailure(
            reason = ConnectionFailure.Reason.HeldElsewhere, title = "Camera in use", message = "Consent required",
            actions = listOf(RecoveryAction.Retry), code = "SIMULATED.held",
        )))
        runCurrent()
        val prompt = assertIs<NikonTakeOverPrompt>(assertIs<ConnectionPrompt.Integration>(assertIs<ConnectionEvent.Progress>(events.single()).prompt).prompt)
        val replacement = backgroundScope.launch { nikon.connect(ConnectTarget.Saved(camera, route.id)).collect {} }
        runCurrent()
        assertEquals(2, port.connects.size)
        prompt.confirm()
        runCurrent()
        assertTrue(port.consentedRequests.isEmpty(), "an old consent cannot admit a request after replacement")
        assertEquals(2, port.connects.size)
        assertTrue(first.isCompleted, "replacement retires the old flow")
        replacement.cancel()
        replacement.join()
    }

    @Test fun aLegacyPortKeepsItsAdmissionThroughTheConfirmedOverload() = runTest {
        val requests = mutableListOf<NikonConnectRequest>()
        val denied = NikonConnectException(NikonIntegration.failure(ConnectionFailure.Reason.HeldElsewhere, "SIMULATED.legacy", "Consent required"))
        val legacy = object : NikonConnectPort {
            override val sightings = MutableStateFlow<List<NikonSighting>>(emptyList())
            override val phase = MutableStateFlow<Pair<NikonConnectionPhase, String?>?>(null)
            override fun savedRecords(): String? = null
            override fun startDiscovery(mode: DiscoveryMode) {}
            override fun stopDiscovery() {}
            override suspend fun connect(request: NikonConnectRequest): NikonConnection {
                requests += request
                throw denied
            }
            override fun cancel() {}
            override fun forget(hosts: List<String>) {}
        }
        val request = NikonConnectRequest.Saved("SIMULATED-host", RouteKind.INFRASTRUCTURE_NETWORK)
        val failure = kotlin.test.assertFailsWith<NikonConnectException> { legacy.connect(request, takingOverConfirmed = true) }
        assertEquals(denied.failure, failure.failure)
        assertEquals(listOf<NikonConnectRequest>(request), requests)
    }

    @Test
    fun failuresAreTyped() {
        val denied = NikonIntegration.failure(
            ConnectionFailure.Reason.Permission(ConnectionFailure.Permission.LOCAL_NETWORK), "local-network.denied", "Allow nearby devices",
        )
        assertEquals(listOf(RecoveryAction.OpenSettings, RecoveryAction.Retry), denied.actions)
        assertEquals("org.opencapture.nikon-ptp.local-network.denied", denied.code)
        assertEquals(listOf(RecoveryAction.Retry), NikonIntegration.failure(ConnectionFailure.Reason.HeldElsewhere, "init.busy", "x").actions)
    }

    @Test
    fun droppingTheAttemptCancelsTheFunnel() = runTest {
        val camera = cameras().last()
        val job = backgroundScope.launch { nikon.connect(ConnectTarget.Saved(camera, camera.routes[0].id)).collect {} }
        runCurrent()
        assertEquals(1, port.connects.size)
        job.cancel()
        runCurrent()
        assertEquals(1, port.cancels)
    }

    /** An attempt starts when collected: the consumer replaces one that has not started by cancelling it. */
    @Test
    fun replacingBeforeTheTaskStartsDoesNotConnectTheOldCamera() = runTest {
        val old = cameras().first()
        val replacement = cameras().last()
        val previous = mutableListOf<ConnectionEvent>()
        backgroundScope.launch { nikon.connect(ConnectTarget.Saved(old, old.routes[0].id)).collect { previous += it } }.cancel()
        val events = mutableListOf<ConnectionEvent>()
        val job = backgroundScope.launch { nikon.connect(ConnectTarget.Saved(replacement, replacement.routes[0].id)).toList(events) }
        runCurrent()
        val expected = NikonConnectRequest.Saved("192.168.43.20", RouteKind.PHONE_HOTSPOT)
        assertEquals(listOf<NikonConnectRequest>(expected), port.connects)
        port.pending.complete(NikonConnection(FakeCameraSession.nikonLike(), "192.168.43.20", RouteKind.PHONE_HOTSPOT))
        job.join()
        assertEquals(replacement.id, assertIs<ConnectionEvent.Connected>(events.last()).camera.saved.id)
        assertTrue(previous.isEmpty(), "the replaced attempt never ran")
    }

    @Test
    fun forgetHandsTheAppEverySetupHost() = runTest {
        nikon.forget(cameras().first())
        assertEquals(listOf(listOf("192.168.50.23", "192.168.1.1")), port.forgotten)
        assertEquals(
            setOf(RouteKind.CAMERA_ACCESS_POINT, RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.PHONE_HOTSPOT, RouteKind.USB),
            nikon.profiles.single().addableRoutes,
        )
    }
}

/** physical-C C9/C10: the phone that lost the camera must not take it straight back. */
class NikonTakeOverRecoveryTest {
    @Test
    fun asksTwiceOnlyBeforeTheFirstAttempt() = runTest {
        val answers = ArrayDeque(listOf(null, "Phone B"))
        var asks = 0
        assertEquals("Phone B", NikonTakeOverRecovery.holder(1) { asks += 1; answers.removeFirst() })
        assertEquals(2, asks)
        asks = 0
        assertEquals(null, NikonTakeOverRecovery.holder(2) { asks += 1; null })
        assertEquals(1, asks)
    }

    /**
     * Hardware pass 4.1: the device that took the camera answers presence only once its session
     * is up, after the body already dropped this one. Two back-to-back sweeps can both land
     * before that answer, so the first attempt keeps asking, spaced, before it may dial.
     */
    @Test
    fun theFirstAttemptKeepsAskingOverASpacedWindow() = runTest {
        val answers = ArrayDeque(listOf(null, null, "Phone B"))
        val pauses = mutableListOf<Long>()
        val holder = NikonTakeOverRecovery.holder(1, pause = { pauses += it }) { answers.removeFirst() }
        assertEquals("Phone B", holder)
        assertEquals(
            List(NikonTakeOverRecovery.FIRST_ATTEMPT_ASKS - 1) { NikonTakeOverRecovery.FIRST_ATTEMPT_ASK_SPACING_MS },
            pauses,
        )
        assertTrue(NikonTakeOverRecovery.FIRST_ATTEMPT_ASKS >= 3)

        var asks = 0
        assertEquals(null, NikonTakeOverRecovery.holder(1, pause = {}) { asks += 1; null })
        assertEquals(NikonTakeOverRecovery.FIRST_ATTEMPT_ASKS, asks)
    }
}
