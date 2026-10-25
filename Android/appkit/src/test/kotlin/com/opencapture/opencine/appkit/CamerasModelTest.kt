package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MonitorPairingInstruction
import com.opencapture.monitorui.MonitorPairingInstructionIcon
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.ConfirmationPrompt
import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionPhase
import com.opencapture.opencine.core.ConnectionPrompt
import com.opencapture.opencine.core.DiscoveryMode
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.IntegrationPresentation
import com.opencapture.opencine.core.NearbyCamera
import com.opencapture.opencine.core.RecoveryAction
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedRoute
import com.opencapture.opencine.core.testing.FakeAttempt
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.FakeIntegration
import com.opencapture.opencine.core.testing.lunaLike
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal object Values {
    val ap = SavedRoute(key = "ap", kind = RouteKind.CAMERA_ACCESS_POINT, network = "CAM-1", bluetooth = true)
    val wifi = SavedRoute(key = "wifi", kind = RouteKind.INFRASTRUCTURE_NETWORK, network = "studio", bluetooth = true)
    val camera = SavedCamera(
        id = "camera-1", integration = IntegrationID("test.cameras"), advertisedName = "CAM-1", model = "Test Body",
        routes = listOf(ap, wifi), preferredRoute = ap.id, lastConnected = 1_000_000,
    )
    val sighting = NearbyCamera("n2", name = "CAM-2", model = "Test Body", routes = setOf(RouteKind.CAMERA_ACCESS_POINT))
    val failure = ConnectionFailure(
        ConnectionFailure.Reason.Permission(ConnectionFailure.Permission.BLUETOOTH), ConnectionPhase.LINK,
        "Bluetooth is off", "Turn on Bluetooth for this app.",
        listOf(RecoveryAction.OpenSettings, RecoveryAction.EditRoute(wifi.id), RecoveryAction.Retry), "test.bluetooth.denied",
    )
    val localNetworkDenied = ConnectionFailure(
        ConnectionFailure.Reason.Permission(ConnectionFailure.Permission.LOCAL_NETWORK), ConnectionPhase.NEGOTIATING,
        "Couldn't connect", "Local Network access is off. Enable it in Settings, then connect again.",
        listOf(RecoveryAction.OpenSettings, RecoveryAction.Retry), "test.local-network.denied",
    )

    fun model(
        integrations: List<FakeIntegration>,
        scope: CoroutineScope,
        saved: List<SavedCamera> = listOf(camera),
        defaults: Defaults = Defaults(emptyMap()),
        routePolicy: CamerasModel.RoutePolicy = CamerasModel.RoutePolicy.PREFERRED,
    ): CamerasModel {
        val store = SavedCamerasStore(defaults.at("document"))
        store.save(saved)
        return CamerasModel(integrations.map { AppIntegration(it) }, store, scope, routePolicy)
    }
}

/** Swift suite `CamerasModelTests`, same method names, against scripted integrations. */
@OptIn(ExperimentalCoroutinesApi::class)
class CamerasModelTest {
    private val fake = FakeIntegration(id = IntegrationID("test.cameras"))
    private val listening = FakeIntegration(id = IntegrationID("test.listening"), discoveryModes = setOf(DiscoveryMode.PASSIVE))
    private val defaults = Defaults(emptyMap())

    private fun TestScope.model(saved: List<SavedCamera> = listOf(Values.camera)) =
        Values.model(listOf(fake, listening), backgroundScope, saved, defaults).also { runCurrent() }

    private val CamerasModel.now get() = state.value

    @Test fun aNeutralPromptReachesOneConsumedShellConsent() = runTest {
        val model = model()
        var admissions = 0
        val prompt = object : ConfirmationPrompt {
            override val confirmationID = "SIMULATED-consent"
            override val confirmationTitle = "Continue?"
            override val fallbackText = "Another operator loses their session."
            override val confirmTitle = "Continue"
            override val cancelTitle = "Cancel"
            override val confirm = { admissions++; Unit }
            override val cancel = {}
        }
        model.connect(Values.camera)
        fake.attempts[0].progress(ConnectionPhase.NEGOTIATING, 0, ConnectionPrompt.Integration(prompt))
        runCurrent()
        assertEquals("Continue?", model.consent.pending.value?.title)
        model.consent.confirm(prompt.confirmationID)
        fake.attempts[0].progress(ConnectionPhase.NEGOTIATING, 0, ConnectionPrompt.Integration(prompt))
        runCurrent()
        model.consent.confirm(prompt.confirmationID)
        assertEquals(1, admissions)
        assertNull(model.consent.pending.value)
    }

    @Test fun retiringTheModelAttemptInvalidatesItsShellConsent() = runTest {
        val model = model()
        var admissions = 0
        val prompt = object : ConfirmationPrompt {
            override val confirmationID = "SIMULATED-retired-consent"
            override val confirmationTitle = "Continue?"
            override val fallbackText = "Consent required"
            override val confirmTitle = "Continue"
            override val cancelTitle = "Cancel"
            override val confirm = { admissions++; Unit }
            override val cancel = {}
        }
        model.connect(Values.camera)
        fake.attempts[0].progress(ConnectionPhase.NEGOTIATING, 0, ConnectionPrompt.Integration(prompt))
        runCurrent()
        assertNotNull(model.consent.pending.value)
        model.cancel(Values.camera.id)
        model.consent.confirm(prompt.confirmationID)
        assertEquals(0, admissions)
        assertNull(model.consent.pending.value)
    }

    @Test
    fun camerasDiscoverPassively() = runTest {
        val model = model()
        assertTrue(fake.liveDiscoveries == listOf(DiscoveryMode.PASSIVE) && listening.liveDiscoveries == listOf(DiscoveryMode.PASSIVE))
        assertTrue(model.now.scanning)
        fake.publish(listOf(Values.sighting))
        runCurrent()
        assertEquals(listOf("n2"), model.now.nearby.map { it.id })
        assertEquals(fake.id, model.now.nearby[0].integration)
    }

    @Test
    fun aBlockedDiscoveryDoesNotClaimToScan() = runTest {
        val blocked =
            FakeIntegration(
                id = IntegrationID("test.blocked"),
                discoveryModes = setOf(DiscoveryMode.PASSIVE),
                discoveryRunning = flowOf(false),
            )
        val model = Values.model(listOf(blocked), backgroundScope)
        runCurrent()
        assertFalse(model.state.value.scanning)
    }

    @Test
    fun thePairPageDiscoversActively() = runTest {
        val model = model()
        model.beginPairing()
        runCurrent()
        assertEquals(listOf(DiscoveryMode.ACTIVE), fake.liveDiscoveries)
        assertEquals(listOf(DiscoveryMode.PASSIVE, DiscoveryMode.ACTIVE), fake.discoveries)
        assertTrue(listening.liveDiscoveries == listOf(DiscoveryMode.PASSIVE) && listening.discoveries == listOf(DiscoveryMode.PASSIVE))
        model.endPairing()
        runCurrent()
        assertEquals(listOf(DiscoveryMode.PASSIVE), fake.liveDiscoveries)
        assertEquals(listOf(DiscoveryMode.PASSIVE, DiscoveryMode.ACTIVE, DiscoveryMode.PASSIVE), fake.discoveries)
    }

    @Test
    fun discoveryStopsWhileAttemptingOrLive() = runTest {
        val model = model()
        model.connect(Values.camera)
        runCurrent()
        assertTrue(fake.liveDiscoveries.isEmpty() && listening.liveDiscoveries.isEmpty())
        assertFalse(model.now.scanning)
        fake.attempts[0].connect(FakeCameraSession.lunaLike())
        runCurrent()
        assertNotNull(model.now.connected)
        assertTrue(model.now.attempts.isEmpty() && fake.liveDiscoveries.isEmpty())
        model.sessionEnded()
        runCurrent()
        assertEquals(listOf(DiscoveryMode.PASSIVE), fake.liveDiscoveries)
        assertTrue(model.now.scanning)
    }

    @Test
    fun aReachableRouteBeatsThePreferredOneOnlyWhenTheAppPrefersIt() = runTest {
        // The camera prefers its access point; a sighting reaches it over Wi-Fi.
        val reaching = NearbyCamera(
            "n1", savedID = Values.camera.id, name = "CAM-1", model = "Test Body",
            routes = setOf(RouteKind.INFRASTRUCTURE_NETWORK), routeKey = Values.wifi.key,
        )
        for ((policy, expected) in listOf(CamerasModel.RoutePolicy.PREFERRED to Values.ap, CamerasModel.RoutePolicy.PREFER_REACHABLE to Values.wifi)) {
            val fake = FakeIntegration(id = IntegrationID("test.cameras"))
            val model = Values.model(listOf(fake), backgroundScope, routePolicy = policy)
            runCurrent()
            assertEquals(Values.ap.id, model.defaultRoute(Values.camera), "$policy")
            fake.publish(listOf(reaching))
            runCurrent()
            assertEquals(listOf(expected.id.text), CamerasMapping.paired(model)[0].setups.filter { it.active }.map { it.id }, "$policy")
            model.connect(Values.camera)
            assertEquals(listOf<ConnectTarget>(ConnectTarget.Saved(Values.camera, expected.id)), fake.attempts.map { it.target }, "$policy")
        }
    }

    @Test
    fun oneAttemptPerCamera() = runTest {
        val model = model()
        model.connect(Values.camera)
        val a = fake.attempts[0]
        a.progress(ConnectionPhase.AWAITING_APPROVAL, 1)
        model.connect(Values.camera, Values.wifi.id)
        val b = fake.attempts[1]
        b.progress(ConnectionPhase.LINK, 0)
        runCurrent()
        assertEquals(b.id, model.now.attempts["camera-1"]?.progress?.attempt)
        assertTrue(a.end != null && b.end == null && model.now.attempts.size == 1)
        assertEquals(ConnectionPhase.LINK, model.now.attempts["camera-1"]?.progress?.phase)
        assertEquals(Values.wifi.id, model.now.attempts["camera-1"]?.route)
        a.progress(ConnectionPhase.NEGOTIATING, 3)
        b.progress(ConnectionPhase.JOINING_NETWORK, 2)
        runCurrent()
        assertEquals(ConnectionPhase.JOINING_NETWORK, model.now.attempts["camera-1"]?.progress?.phase)
        assertEquals(b.id, model.now.attempts["camera-1"]?.progress?.attempt)
    }

    @Test
    fun cancelEndsTheAttempt() = runTest {
        val model = model()
        model.connect(Values.camera)
        model.cancel("camera-1")
        assertTrue(model.now.attempts.isEmpty())
        runCurrent()
        assertEquals(FakeAttempt.End.CANCELLED, fake.attempts[0].end)
        assertEquals(listOf(DiscoveryMode.PASSIVE), fake.liveDiscoveries)
    }

    @Test
    fun failuresOfferTheirActions() = runTest {
        val model = model()
        model.connect(Values.camera, Values.wifi.id)
        fake.attempts[0].fail(Values.failure)
        runCurrent()
        assertEquals(Values.failure, model.now.failures["camera-1"]?.failure)
        assertTrue(model.now.attempts.isEmpty())
        assertEquals(
            CamerasModel.Request.OpenSettings(Values.failure.reason),
            model.perform(RecoveryAction.OpenSettings, "camera-1"),
        )
        assertEquals(
            CamerasModel.Request.EditRoute(Values.camera, Values.wifi.id),
            model.perform(RecoveryAction.EditRoute(Values.wifi.id), "camera-1"),
        )
        assertNull(model.perform(RecoveryAction.Retry, "camera-1"))
        assertTrue(fake.attempts.size == 2 && fake.attempts[1].target == ConnectTarget.Saved(Values.camera, Values.wifi.id))
        assertTrue(model.now.failures.isEmpty() && model.now.attempts["camera-1"] != null)
    }

    @Test
    fun returningToTheAppRetriesARecordedFailureThroughAnAttempt() = runTest {
        val model = model()
        model.connect(Values.camera)
        fake.attempts[0].fail(Values.failure)
        runCurrent()
        assertEquals(1, fake.attempts.size)

        model.retryCurrentFailures()
        runCurrent()

        assertEquals(2, fake.attempts.size, "the foreground retry is a real attempt with card progress")
        assertEquals(ConnectTarget.Saved(Values.camera, Values.ap.id), fake.attempts[1].target)
        assertNull(model.now.failures[Values.camera.id])
        assertNotNull(model.now.attempts[Values.camera.id])
    }

    @Test
    fun aForegroundRetryUsesTheCurrentSavedRecord() = runTest {
        val model = model()
        model.connect(Values.camera)
        fake.attempts[0].fail(Values.failure)
        runCurrent()
        model.rename(Values.camera.id, "Renamed")
        runCurrent()

        model.retryCurrentFailures()
        runCurrent()

        val target = assertIs<ConnectTarget.Saved>(fake.attempts.last().target)
        assertEquals("Renamed", target.camera.name, "the retry must not restore the record from the failure")
        assertEquals(Values.ap.id, target.route)
    }

    @Test
    fun aForegroundRetrySkipsAFailedRouteTheOperatorForgot() = runTest {
        val model = model()
        model.connect(Values.camera)
        fake.attempts[0].fail(Values.failure)
        runCurrent()
        model.forgetRoute(Values.ap.id, Values.camera.id)
        runCurrent()

        model.retryCurrentFailures()
        runCurrent()

        assertEquals(1, fake.attempts.size, "a forgotten route must not come back through the retry")
    }

    @Test
    fun aForegroundRetryLeavesALiveSessionAlone() = runTest {
        val model = model()
        model.connect(Values.camera)
        fake.attempts[0].fail(Values.failure)
        runCurrent()
        model.connect(Values.camera)
        fake.attempts[1].connect(FakeCameraSession.lunaLike())
        runCurrent()
        assertEquals(2, fake.attempts.size)

        model.retryCurrentFailures()
        runCurrent()

        assertEquals(2, fake.attempts.size, "a live camera is never re-dialled")
    }

@Test
    fun localNetworkFailuresConnectAgainWhenRechecked() = runTest {
        val model = model(saved = emptyList())
        fake.publish(listOf(Values.sighting))
        model.beginPairing()
        runCurrent()
        model.select("n2")
        model.connect(model.now.nearby.first())
        fake.attempts[0].fail(Values.localNetworkDenied)
        runCurrent()
        assertNotNull(model.now.failures["n2"])
        model.retryLocalNetworkFailures()
        runCurrent()
        assertTrue(fake.attempts.size == 2 && fake.attempts[1].target == ConnectTarget.Nearby(Values.sighting))
        assertTrue(model.now.failures.isEmpty() && model.now.attempts["n2"] != null)
        model.retryLocalNetworkFailures()
        runCurrent()
        assertEquals(2, fake.attempts.size, "a running attempt is never replaced")
    }

    /** A re-check dials the current saved record, never a route forgotten since (CodeRabbit, #262). */
    @Test
    fun aRecheckSkipsAForgottenRoute() = runTest {
        val model = model()
        model.connect(Values.camera, Values.wifi.id)
        fake.attempts[0].fail(Values.localNetworkDenied)
        runCurrent()
        model.rename("camera-1", "A camera")
        model.retryLocalNetworkFailures()
        runCurrent()
        assertEquals(2, fake.attempts.size)
        assertEquals(ConnectTarget.Saved(model.now.saved[0], Values.wifi.id), fake.attempts.last().target, "the current record")
        fake.attempts[1].fail(Values.localNetworkDenied)
        runCurrent()
        model.forgetRoute(Values.wifi.id, "camera-1")
        model.retryLocalNetworkFailures()
        runCurrent()
        assertEquals(2, fake.attempts.size, "the forgotten route is not dialled")
    }

    @Test
    fun otherFailuresWaitForTheOperatorWhenRechecked() = runTest {
        val model = model()
        model.connect(Values.camera)
        fake.attempts[0].fail(Values.failure)
        runCurrent()
        model.retryLocalNetworkFailures()
        runCurrent()
        assertTrue(fake.attempts.size == 1 && model.now.failures["camera-1"]?.failure == Values.failure)
    }

        @Test
    fun promptsReachTheCardAndThePairPage() = runTest {
        val model = model(saved = emptyList())
        fake.publish(listOf(Values.sighting))
        model.beginPairing()
        runCurrent()
        model.select("n2")
        model.connect(model.now.nearby.first())
        fake.attempts[0].progress(ConnectionPhase.AWAITING_APPROVAL, 1, ConnectionPrompt.ApproveOnCamera("Tap Allow on the camera"))
        runCurrent()
        assertEquals("Tap Allow on the camera", model.now.attempts["n2"]?.prompt?.text)
        val pairing = CamerasMapping.pairing(model)
        assertTrue(pairing.currentStep == 2 && pairing.title == "Approve")
        assertEquals(
            listOf(MonitorPairingInstruction("On the camera", MonitorPairingInstructionIcon.CAMERA, listOf("Tap Allow on the camera"))),
            pairing.instructions,
        )
        assertTrue(pairing.progress == "Approve" && pairing.backAction == "Cancel")
    }

    @Test
    fun connectingUpsertsTheSavedRecord() = runTest {
        val model = model()
        val connected = mutableListOf<String>()
        model.onConnected = { connected += it.saved.id }
        fake.publish(listOf(Values.sighting))
        runCurrent()
        model.connect(model.now.nearby.first())
        fake.attempts[0].connect(FakeCameraSession.lunaLike())
        runCurrent()
        assertEquals(listOf("n2", "camera-1"), model.now.saved.map { it.id })
        assertEquals(listOf("n2"), connected)
        model.sessionEnded()

        val again = Values.camera.copy(lastConnected = 2_000_000)
        model.connect(Values.camera)
        fake.attempts[1].connect(FakeCameraSession.lunaLike(), again)
        runCurrent()
        assertEquals(listOf("n2", "camera-1"), model.now.saved.map { it.id })
        assertEquals(again, model.now.saved[1])
        val stored = SavedCamerasStore(defaults.at("document")).apply { load() }
        assertEquals(model.now.saved, stored.cameras)
    }

    @Test
    fun forgetCallsTheIntegration() = runTest {
        val model = model()
        model.forget("camera-1")
        assertTrue(fake.forgotten == listOf(Values.camera) && model.now.saved.isEmpty())
    }

    @Test
    fun renameRouteKeepsItsIdentityAndOtherSetups() = runTest {
        val model = model()
        model.renameRoute(Values.wifi.id, Values.camera.id, "  Stage right ")
        val expected = Values.camera.copy(routes = listOf(Values.ap, Values.wifi.copy(title = "Stage right")))
        assertEquals(listOf(expected), model.now.saved)
        assertEquals("Stage right", CamerasMapping.paired(model)[0].setups[1].title)
        model.reloadSaved()
        assertEquals(listOf(expected), model.now.saved)
        model.renameRoute(com.opencapture.opencine.core.ConnectionRouteID(), Values.camera.id, "Unknown route")
        model.renameRoute(Values.wifi.id, "missing", "Unknown camera")
        assertEquals(listOf(expected), model.now.saved)
        model.renameRoute(Values.wifi.id, Values.camera.id, " \n ")
        assertEquals(listOf(Values.camera), model.now.saved)
        assertEquals("Wi-Fi · studio", CamerasMapping.paired(model)[0].setups[1].title)
    }

    @Test
    fun singleRouteCanBeRenamedAndReset() = runTest {
        val camera = Values.camera.copy(routes = listOf(Values.ap))
        val model = model(listOf(camera))
        model.renameRoute(Values.ap.id, camera.id, "Rig")
        assertEquals("Rig", model.now.saved[0].routes[0].title)
        assertFalse(CamerasMapping.paired(model)[0].setups[0].canForget)
        model.renameRoute(Values.ap.id, camera.id, null)
        model.reloadSaved()
        assertEquals(listOf(camera), model.now.saved)
    }

    @Test
    fun setupRenameWaitsUntilConnectionAttemptEnds() = runTest {
        val model = model()
        model.connect(Values.camera)
        model.renameRoute(Values.ap.id, Values.camera.id, "Rig")
        assertEquals(listOf(Values.camera), model.now.saved)
        model.cancel(Values.camera.id)
        model.renameRoute(Values.ap.id, Values.camera.id, "Rig")
        assertEquals("Rig", model.now.saved[0].routes[0].title)
    }

    @Test
    fun renameAndForgetARoute() = runTest {
        val model = model()
        model.rename("camera-1", "  A cam ")
        model.forgetRoute(Values.ap.id, "camera-1")
        assertTrue(model.now.saved[0].name == "A cam" && model.now.saved[0].routes == listOf(Values.wifi))
        assertNull(model.now.saved[0].preferredRoute)
        model.rename("camera-1", " ")
        assertNull(model.now.saved[0].name)
    }

    @Test
    fun upsertSavesWhatAnIntegrationRemembers() = runTest {
        val model = model()
        model.upsert(Values.camera.copy(preferredRoute = Values.wifi.id))
        model.upsert(Values.camera.copy(id = "camera-2"))
        assertEquals(listOf("camera-2", "camera-1"), model.now.saved.map { it.id })
        assertEquals(Values.wifi.id, model.now.saved[1].preferredRoute)
        assertEquals(listOf("camera-2", "camera-1"), SavedCamerasStore(defaults.at("document")).also { it.load() }.cameras.map { it.id })
    }

    @Test
    fun reloadMergesWhatTheAppSavedItself() = runTest {
        val legacy = Defaults(mapOf("records" to """[{"id":"camera-9","advertisedName":"CAM-9","modelName":"Test Body","lastConnectedAt":0}]"""))
        val store = SavedCamerasStore(
            defaults.at("document"),
            SavedCamerasStore.Legacy(legacy.at("records"), BodyRecordsV0(IntegrationID("test.cameras"), BodyRecordsV0.Dates.EPOCH_MILLISECONDS), "records"),
        )
        val model = CamerasModel(listOf(AppIntegration(fake)), store, backgroundScope)
        assertEquals(listOf("camera-9"), model.now.saved.map { it.id })
        legacy.values["records"] = """[{"id":"camera-9","advertisedName":"CAM-9","modelName":"Test Body","lastConnectedAt":0,"customName":"Nine"}]"""
        model.reloadSaved()
        assertEquals(listOf<String?>("Nine"), model.now.saved.map { it.name })
        // A save from the model keeps the app's write.
        model.rename("camera-9", "Nine")
        assertTrue(legacy.writes.isEmpty())
    }

    /**
     * A nearby card's tap is the integration's declared behavior (A4-39), not an app's copied pair
     * lambda: an integration whose camera approves the pairing connects at once, any other only
     * chooses the camera for the pair page's Connect.
     */
    @Test
    fun nearbyTapFollowsTheIntegrationsPresentation() = runTest {
        val pairsOnTap = FakeIntegration(
            id = IntegrationID("test.pairs-on-tap"),
            presentation = IntegrationPresentation(nearbyTap = IntegrationPresentation.NearbyTap.CONNECT),
        )
        val model = Values.model(listOf(fake, pairsOnTap), backgroundScope, emptyList(), defaults).also { runCurrent() }
        fake.publish(listOf(Values.sighting))
        pairsOnTap.publish(listOf(Values.sighting.copy(id = "n3", name = "CAM-3")))
        runCurrent()

        model.openNearby("n2")
        assertEquals("n2", model.now.selection)
        assertTrue(model.now.attempts.isEmpty() && fake.attempts.isEmpty())

        model.openNearby("n3")
        assertEquals("n3", model.now.selection)
        assertEquals(listOf("n3"), model.now.attempts.keys.toList())
        assertEquals(ConnectTarget.Nearby(Values.sighting.copy(id = "n3", name = "CAM-3")), pairsOnTap.attempts.single().target)
    }

    /** Rename setup is offered where the camera's integration names setups (A4-39: no brand Boolean). */
    @Test
    fun setupNamesFollowTheIntegrationsPresentation() = runTest {
        val unnamed = FakeIntegration(id = IntegrationID("test.unnamed"), presentation = IntegrationPresentation(namesSetups = false))
        val other = Values.camera.copy(id = "camera-2", integration = unnamed.id)
        val model = Values.model(listOf(fake, unnamed), backgroundScope, listOf(Values.camera, other), defaults).also { runCurrent() }
        assertTrue(model.namesSetups(Values.camera))
        assertFalse(model.namesSetups(other))
    }
}
