package com.opencapture.opencine.core

import com.opencapture.opencine.core.testing.FakeAttempt
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.FakeIntegration
import com.opencapture.opencine.core.testing.lunaLike
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.yield
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Swift suite `IntegrationContract`, same method names, against the scripted [FakeIntegration]. */
class IntegrationContractTest {
    private val route = SavedRoute(key = "ap", kind = RouteKind.CAMERA_ACCESS_POINT, network = "CAM-1", bluetooth = true)
    private val camera = SavedCamera(
        id = "camera-1", integration = IntegrationID("test.fake-integration"), advertisedName = "CAM-1",
        model = "Test Body", routes = listOf(route),
    )
    private val failure = ConnectionFailure(
        ConnectionFailure.Reason.TimedOut, ConnectionPhase.AWAITING_APPROVAL, "Not approved",
        "Approve on the camera.", listOf(RecoveryAction.Retry), "test.approval.timeout",
    )

    @Test
    fun discoveryYieldsTheLatestList() = scenario {
        val integration = FakeIntegration()
        val nearby = NearbyCamera("n1", name = "CAM-1", model = "Test Body", routes = setOf(RouteKind.CAMERA_ACCESS_POINT))
        val lists = mutableListOf<List<NearbyCamera>>()
        val job = launch(start = CoroutineStart.UNDISPATCHED) { integration.discover(DiscoveryMode.PASSIVE).collect { lists += it } }
        integration.publish(listOf(nearby))
        settle()
        assertEquals(listOf(emptyList(), listOf(nearby)), lists)
        job.cancel()
    }

    @Test
    fun anUnlistedModeFinishesAtOnce() = scenario {
        val integration = FakeIntegration(discoveryModes = setOf(DiscoveryMode.PASSIVE), endpoints = listOf("10.0.0.2"))
        assertTrue(integration.discover(DiscoveryMode.ACTIVE).toList().isEmpty())
        assertTrue(integration.discoveries.isEmpty() && integration.dials.isEmpty())
    }

    @Test
    fun cancellingDiscoveryStopsIt() = scenario {
        val integration = FakeIntegration()
        val job = launch(start = CoroutineStart.UNDISPATCHED) { integration.discover(DiscoveryMode.PASSIVE).collect {} }
        assertEquals(listOf(DiscoveryMode.PASSIVE), integration.liveDiscoveries)
        job.cancel()
        job.join()
        assertTrue(integration.liveDiscoveries.isEmpty())
    }

    @Test
    fun aLateEventFromAttemptANeverUpdatesAttemptB() = scenario {
        val integration = FakeIntegration()
        val target = ConnectTarget.Saved(camera, route.id)
        val eventsA = mutableListOf<ConnectionEvent>()
        val jobA = collecting(integration.connect(target), eventsA)
        val a = integration.attempts[0]
        a.progress(ConnectionPhase.LINK, 0)
        val eventsB = mutableListOf<ConnectionEvent>()
        val jobB = collecting(integration.connect(target), eventsB)
        val b = integration.attempts[1]
        a.progress(ConnectionPhase.AWAITING_APPROVAL, 1)
        a.fail(failure)
        b.progress(ConnectionPhase.LINK, 0)
        b.connect(FakeCameraSession.lunaLike())
        jobA.join()
        jobB.join()

        assertEquals(listOf("progress LINK 0"), eventsA.map(::summary))
        assertEquals(listOf(a.id), eventsA.mapNotNull(::attempt))
        assertEquals(listOf("progress LINK 0", "connected camera-1"), eventsB.map(::summary))
        assertEquals(listOf(b.id), eventsB.mapNotNull(::attempt))
        assertTrue(a.end == FakeAttempt.End.SUPERSEDED && a.dropped == 2)
        assertEquals(FakeAttempt.End.CONNECTED, b.end)
    }

    @Test
    fun attemptsForDifferentCamerasRunSideBySide() = scenario {
        val integration = FakeIntegration()
        val first = collecting(integration.connect(ConnectTarget.Saved(camera, route.id)), mutableListOf())
        val nearby = NearbyCamera("n2", name = "CAM-2", model = "Test Body", routes = setOf(RouteKind.CAMERA_ACCESS_POINT))
        val second = collecting(integration.connect(ConnectTarget.Nearby(nearby)), mutableListOf())
        assertEquals(listOf(null, null), integration.attempts.map { it.end })
        first.cancel()
        second.cancel()
    }

    @Test
    fun cancellingTheConsumerCancelsTheAttempt() = scenario {
        val integration = FakeIntegration()
        val job = collecting(integration.connect(ConnectTarget.Saved(camera, route.id)), mutableListOf())
        val attempt = integration.attempts[0]
        job.cancel()
        job.join()
        assertEquals(FakeAttempt.End.CANCELLED, attempt.end)
        attempt.progress(ConnectionPhase.LINK, 0)
        assertEquals(1, attempt.dropped)
    }

    @Test
    fun connectedAndFailedAreTerminal() = scenario {
        val integration = FakeIntegration()
        val first = mutableListOf<ConnectionEvent>()
        val firstJob = collecting(integration.connect(ConnectTarget.Saved(camera, route.id)), first)
        val connected = integration.attempts[0]
        connected.connect(FakeCameraSession.lunaLike())
        connected.progress(ConnectionPhase.LINK, 0)
        connected.fail(failure)
        firstJob.join()
        assertEquals(listOf("connected camera-1"), first.map(::summary))

        val second = mutableListOf<ConnectionEvent>()
        val secondJob = collecting(integration.connect(ConnectTarget.Saved(camera, route.id)), second)
        val failed = integration.attempts[1]
        failed.progress(ConnectionPhase.AWAITING_APPROVAL, 1, ConnectionPrompt.ApproveOnCamera("Approve on the camera"))
        failed.fail(failure)
        failed.connect(FakeCameraSession.lunaLike())
        secondJob.join()
        assertEquals(listOf("progress AWAITING_APPROVAL 1 prompt", "failed test.approval.timeout"), second.map(::summary))
        assertTrue(connected.dropped == 2 && failed.dropped == 1)
    }

    @Test
    fun aFirstConnectBuildsTheRecordFromTheSighting() = scenario {
        val integration = FakeIntegration()
        val nearby = NearbyCamera(
            "n1", name = "CAM-1", model = "Test Body",
            routes = setOf(RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.CAMERA_ACCESS_POINT),
        )
        val events = mutableListOf<ConnectionEvent>()
        val job = collecting(integration.connect(ConnectTarget.Nearby(nearby)), events)
        integration.attempts[0].connect(FakeCameraSession.lunaLike())
        job.join()
        val saved = (events.last() as ConnectionEvent.Connected).camera.saved
        assertTrue(saved.id == "n1" && saved.integration == integration.id)
        assertEquals(listOf(RouteKind.CAMERA_ACCESS_POINT, RouteKind.INFRASTRUCTURE_NETWORK), saved.routes.map { it.kind })
    }

    @Test
    fun anAttemptHandlerAnswersEveryConnect() = scenario {
        val integration = FakeIntegration()
        integration.onAttempt = { it.connect(FakeCameraSession.lunaLike()) }
        val nearby = NearbyCamera("n1", name = "CAM-1", model = "Test Body", routes = setOf(RouteKind.CAMERA_ACCESS_POINT))
        val events = integration.connect(ConnectTarget.Nearby(nearby)).toList()
        assertEquals(listOf("connected n1"), events.map(::summary))
        assertEquals(listOf(FakeAttempt.End.CONNECTED), integration.attempts.map { it.end })
    }

    @Test
    fun forgetReachesTheIntegration() = scenario {
        val integration = FakeIntegration()
        integration.forget(camera)
        assertEquals(listOf(camera), integration.forgotten)
    }

    @Test
    fun servicesAreLookedUpByType() {
        val none = CameraServices()
        assertNull(none.get<Greeting>())
        val services = none.plus(Greeting::class, English())
        assertEquals("hello", services.get<Greeting>()?.hello)
        assertNull(services.get<English>())
        assertNull(none.get<Greeting>())
    }

    @Test
    fun aDraftNeverPrintsItsSecret() {
        val draft = RouteDraft(RouteKind.INFRASTRUCTURE_NETWORK, network = "studio", secret = "hunter2")
        for (text in listOf(draft.toString(), "$draft")) {
            assertTrue("studio" in text)
            assertFalse("hunter2" in text)
        }
    }

    @Test
    fun targetsNameTheirCamera() {
        val sighting = NearbyCamera("n1", name = "CAM-1", model = "Test Body", routes = emptySet())
        assertEquals("camera-1", ConnectTarget.Saved(camera, route.id).cameraID)
        assertEquals("camera-1", ConnectTarget.AddRoute(camera, RouteDraft(RouteKind.PHONE_HOTSPOT)).cameraID)
        assertEquals("n1", ConnectTarget.Nearby(sighting).cameraID)
        assertEquals("camera-1", ConnectTarget.Nearby(sighting.copy(savedID = "camera-1")).cameraID)
        assertEquals("Tap Join", ConnectionPrompt.AcceptNetworkJoin("CAM-1", "Tap Join").text)
    }

    private interface Greeting {
        val hello: String
    }

    private class English : Greeting {
        override val hello = "hello"
    }
}

/** Collects [events] into [into] from now on; the attempt starts before this returns. */
fun CoroutineScope.collecting(events: Flow<ConnectionEvent>, into: MutableList<ConnectionEvent>): Job =
    launch(start = CoroutineStart.UNDISPATCHED) { events.collect { into += it } }

/** Lets every collector on this thread catch up. */
suspend fun settle() = repeat(10) { yield() }

fun summary(event: ConnectionEvent): String = when (event) {
    is ConnectionEvent.Progress ->
        "progress ${event.progress.phase} ${event.progress.current}" + if (event.prompt == null) "" else " prompt"
    is ConnectionEvent.Connected -> "connected ${event.camera.saved.id}"
    is ConnectionEvent.Failed -> "failed ${event.failure.code}"
}

fun attempt(event: ConnectionEvent): ConnectionAttemptID? = (event as? ConnectionEvent.Progress)?.progress?.attempt
