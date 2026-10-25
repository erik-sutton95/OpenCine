package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ConnectedCamera
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.DiscoveryMode
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.FakeIntegration
import com.opencapture.opencine.core.testing.lunaLike
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/**
 * Swift suite `ShellModelTests`, same method names: the shell's root state and monitor lifetime
 * through the shared interface, a scripted integration and fake sessions on virtual time.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class ShellModelTest {
    private val fake = FakeIntegration(id = IntegrationID("test.cameras"))
    private val other = SavedCamera(
        id = "camera-2", integration = IntegrationID("test.cameras"), advertisedName = "CAM-2", model = "Test Body",
        routes = listOf(Values.ap), preferredRoute = Values.ap.id,
    )

    private fun TestScope.shell(saved: List<SavedCamera> = listOf(Values.camera, other)): ShellModel =
        ShellModel(Values.model(listOf(fake), backgroundScope, saved), MonitorControlModel(backgroundScope)).also { runCurrent() }

    /** Connects [camera] through the connection model with [session]. */
    private fun TestScope.connect(shell: ShellModel, camera: SavedCamera, session: CameraSession) {
        shell.cameras.connect(camera)
        runCurrent()
        fake.liveAttempt(camera.id)?.connect(session)
        runCurrent()
        assertEquals(session.id, shell.state.value.monitor?.session?.id)
    }

    private val ShellModel.monitor get() = state.value.monitor
    private val ShellModel.cover get() = state.value.cover

    @Test
    fun routesFollowSavedCamerasPairingAndTheMonitor() = runTest {
        assertEquals(ShellModel.Route.PAIR, shell(saved = emptyList()).route)
        val empty = shell(saved = emptyList())
        empty.showCameras()
        assertEquals(ShellModel.Route.CAMERAS, empty.route, "the operator chose the list")
        empty.beginPairing()
        assertEquals(ShellModel.Route.PAIR, empty.route)
        val shell = shell()
        assertEquals(ShellModel.Route.CAMERAS, shell.route)
        shell.beginPairing()
        assertEquals(ShellModel.Route.PAIR, shell.route)
        shell.open(ShellModel.Cover.SETTINGS)
        connect(shell, Values.camera, Counted(FakeCameraSession.lunaLike()))
        assertTrue(
            shell.route == ShellModel.Route.MONITOR && !shell.state.value.pairing && shell.cover == null,
            "connecting ends pairing and covers",
        )
        shell.close()
        assertEquals(ShellModel.Route.CAMERAS, shell.route)
    }

    /**
     * Hardware pass 8.0: the Local Network prompt and a Settings visit both take the scene
     * inactive; coming back re-checks a Local Network failure by connecting again, once.
     */
    @Test
    fun becomingActiveRechecksALocalNetworkFailure() = runTest {
        val shell = shell()
        shell.cameras.connect(Values.camera)
        runCurrent()
        fake.attempts[0].fail(Values.localNetworkDenied)
        runCurrent()
        assertNotNull(shell.cameras.state.value.failures[Values.camera.id])
        shell.setSceneActive(true)
        runCurrent()
        assertEquals(1, fake.attempts.size, "no change of activity, no re-check")
        shell.setSceneActive(false)
        runCurrent()
        assertEquals(1, fake.attempts.size)
        shell.setSceneActive(true)
        runCurrent()
        assertTrue(fake.attempts.size == 2 && shell.cameras.state.value.failures.isEmpty())
    }

    /** One integration is one backend: a re-check dials one of its cameras, never two at once. */
    @Test
    fun aRecheckDialsOneCameraPerIntegration() = runTest {
        val shell = shell()
        shell.cameras.connect(Values.camera)
        runCurrent()
        fake.attempts[0].fail(Values.localNetworkDenied)
        runCurrent()
        shell.cameras.connect(other)
        runCurrent()
        fake.attempts[1].fail(Values.localNetworkDenied)
        runCurrent()
        assertEquals(2, shell.cameras.state.value.failures.size)
        shell.setSceneActive(false)
        shell.setSceneActive(true)
        runCurrent()
        assertTrue(fake.attempts.size == 3 && shell.cameras.state.value.attempts.size == 1)
    }

    /** A live camera is never replaced by a re-check of an older failure (CodeRabbit, #262). */
    @Test
    fun aRecheckLeavesALiveCameraAlone() = runTest {
        val shell = shell()
        shell.cameras.connect(Values.camera)
        runCurrent()
        fake.attempts[0].fail(Values.localNetworkDenied)
        runCurrent()
        connect(shell, other, Counted(FakeCameraSession.lunaLike()))
        shell.setSceneActive(false)
        shell.setSceneActive(true)
        runCurrent()
        assertEquals(2, fake.attempts.size, "the live camera keeps its session")
    }

    @Test
    fun connectAThenReplaceWithBAndDeliverALate() = runTest {
        val shell = shell()
        val a = Counted(FakeCameraSession.lunaLike())
        val b = Counted(FakeCameraSession.lunaLike())
        a.fake.cameraReportsStatus()
        b.fake.cameraReportsStatus()
        connect(shell, Values.camera, a)
        shell.control.set(iso(800), "ISO 800")
        advanceTimeBy(120)
        runCurrent()
        assertEquals(1, a.fake.wire.size)
        val first = shell.monitor?.id

        connect(shell, other, b)
        assertTrue(shell.monitor?.id != first && shell.cameras.state.value.connected?.session?.id == b.id)
        assertEquals(listOf(SessionCloseReason.REPLACED), a.closes)
        // A answers late, and reports again: nothing reaches B's monitor.
        a.fake.advance(10.seconds)
        a.fake.cameraReportsStatus()
        runCurrent()
        assertTrue(shell.monitor?.session?.id == b.id && shell.control.state.value.session?.id == b.id)
        assertTrue(shell.control.state.value.snapshot?.session == b.id && shell.control.state.value.pending.isEmpty())
        assertTrue(b.closes.isEmpty())
    }

    @Test
    fun presentingTheSameSessionPreservesTheMonitorLifetime() = runTest {
        val shell = shell()
        val camera = Counted(FakeCameraSession.lunaLike())
        camera.fake.cameraReportsStatus()
        connect(shell, Values.camera, camera)
        val first = assertNotNull(shell.monitor)
        val editor = assertNotNull(shell.control.edit(SettingKey.ISO))
        shell.open(ShellModel.Cover.SETTINGS)
        shell.present(first.camera)
        runCurrent()
        assertEquals(first.id, shell.monitor?.id)
        assertEquals(ShellModel.Cover.SETTINGS, shell.cover)
        assertTrue(shell.control.isCurrent(editor))
        assertTrue(camera.closes.isEmpty())
    }

    @Test
    fun leavingTheMonitorCanRetainItsCover() = runTest {
        val shell = shell()
        val camera = Counted(FakeCameraSession.lunaLike())
        connect(shell, Values.camera, camera)
        shell.open(ShellModel.Cover.MEDIA)
        shell.close(ShellModel.CoverRetention.RETAIN)
        runCurrent()
        assertTrue(shell.monitor == null && shell.route == ShellModel.Route.CAMERAS)
        assertEquals(ShellModel.Cover.MEDIA, shell.cover, "the cover is never cleared, so its page keeps its identity")
        assertEquals(listOf(SessionCloseReason.REQUESTED), camera.closes)
    }

    @Test
    fun closeOnce() = runTest {
        val shell = shell()
        val camera = Counted(FakeCameraSession.lunaLike())
        connect(shell, Values.camera, camera)
        shell.close()
        shell.close()
        runCurrent()
        assertEquals(listOf(SessionCloseReason.REQUESTED), camera.closes)
        assertTrue(shell.monitor == null && shell.cameras.state.value.connected == null && shell.control.state.value.session == null)
        assertEquals(listOf(DiscoveryMode.PASSIVE), fake.liveDiscoveries, "discovery resumes")
    }

    @Test
    fun disconnectDuringPendingEdit() = runTest {
        val shell = shell()
        val notes = mutableListOf<String>()
        shell.control.onNote = { notes += it }
        val camera = Counted(FakeCameraSession.lunaLike())
        camera.fake.cameraReportsStatus()
        connect(shell, Values.camera, camera)
        shell.control.set(iso(800), "ISO 800")
        // The session ends on its own (the integration gave up the link) before the edit is sent.
        camera.close(SessionCloseReason.LINK_LOST)
        runCurrent()
        assertNull(shell.monitor)
        assertTrue(shell.control.state.value.pending.isEmpty() && shell.cameras.state.value.connected == null)
        advanceTimeBy(1_000)
        runCurrent()
        assertTrue(camera.fake.wire.isEmpty())
        assertTrue(notes.isEmpty())
        assertEquals(listOf(SessionCloseReason.LINK_LOST), camera.closes, "the shell does not close it again")
    }

    @Test
    fun closeWhileRecordingSendsNoStop() = runTest {
        val shell = shell()
        val camera = Counted(FakeCameraSession.lunaLike())
        camera.fake.cameraReportsStatus()
        connect(shell, Values.camera, camera)
        shell.control.record(true)
        runCurrent()
        assertEquals(listOf("record-start"), camera.fake.wire)
        camera.fake.advance(3.seconds)
        runCurrent()
        assertEquals(true, shell.control.isRecording)
        shell.close()
        runCurrent()
        assertEquals(listOf(SessionCloseReason.REQUESTED), camera.closes)
        assertEquals(listOf("record-start"), camera.fake.wire)
        assertEquals(true, camera.fake.device.recording, "the camera keeps recording")
    }

    @Test
    fun cameraGalleryOpensAndClosesOnlyTheMediaCover() = runTest {
        val shell = shell()
        shell.followCameraGallery(open = true)
        assertEquals(ShellModel.Cover.MEDIA, shell.state.value.cover)
        shell.followCameraGallery(open = false)
        assertNull(shell.state.value.cover)
        shell.open(ShellModel.Cover.SETTINGS)
        shell.followCameraGallery(open = true)
        assertEquals(ShellModel.Cover.SETTINGS, shell.state.value.cover)
        shell.followCameraGallery(open = false)
        assertEquals(ShellModel.Cover.SETTINGS, shell.state.value.cover)
    }

    @Test
    fun coverAndRevealPreserveTheHostAndConnection() = runTest {
        val shell = shell()
        val camera = Counted(FakeCameraSession.lunaLike())
        camera.fake.cameraReportsStatus()
        connect(shell, Values.camera, camera)
        val host = shell.monitor?.id
        shell.open(ShellModel.Cover.SETTINGS)
        assertTrue(shell.route == ShellModel.Route.MONITOR && shell.cover == ShellModel.Cover.SETTINGS && shell.monitor?.id == host)
        shell.dismissCover()
        shell.open(ShellModel.Cover.MEDIA)
        shell.dismissCover()
        assertTrue(shell.cover == null && shell.monitor?.id == host && shell.control.state.value.session?.id == camera.id)
        runCurrent()
        assertTrue(camera.closes.isEmpty())
        // Leaving the monitor drops a cover with it; the cameras page has its own covers.
        shell.open(ShellModel.Cover.MEDIA)
        shell.close()
        assertNull(shell.cover)
        shell.open(ShellModel.Cover.SETTINGS)
        assertTrue(shell.route == ShellModel.Route.CAMERAS && shell.cover == ShellModel.Cover.SETTINGS)
    }

    @Test
    fun liveLinkLossRetainsTheHeldPicture() = runTest {
        val shell = shell()
        val fakeSession = FakeCameraSession.lunaLike()
        fakeSession.cameraReportsStatus()
        connect(shell, Values.camera, Counted(fakeSession))
        assertEquals(iso(200), shell.control.shown(SettingKey.ISO))
        val host = shell.monitor?.id
        val editor = assertNotNull(shell.control.edit(SettingKey.ISO))
        val attempt = fakeSession.loseLink()
        runCurrent()
        assertTrue(shell.control.state.value.snapshot?.connection is ConnectionState.Recovering)
        assertEquals(host, shell.monitor?.id, "recovery is the integration's: the monitor stays")
        assertEquals(iso(200), shell.control.shown(SettingKey.ISO), "last reported values are held")
        fakeSession.completeAttempt(attempt)
        runCurrent()
        assertEquals(ConnectionState.Ready, shell.control.state.value.snapshot?.connection)
        assertFalse(shell.control.isCurrent(editor), "a new control epoch obsoletes the editor")
        assertEquals(host, shell.monitor?.id)
    }

    @Test
    fun staleRecordReceiptCannotOverwriteTheReplacementSession() = runTest {
        val shell = shell()
        val a = FakeCameraSession.lunaLike()
        val b = FakeCameraSession.lunaLike()
        a.cameraReportsStatus()
        b.cameraReportsStatus()
        val finished = mutableListOf<CameraSessionID>()
        shell.control.onRecordFinished = { finished += it.session }
        connect(shell, Values.camera, Counted(a))
        shell.control.record(true)
        runCurrent()
        assertEquals(listOf("record-start"), a.wire)
        connect(shell, other, Counted(b))
        assertFalse(shell.control.state.value.recordPending)
        a.advance(3.seconds)
        runCurrent()
        assertTrue(finished.isEmpty() && !shell.control.state.value.recordPending)
        shell.control.record(true)
        runCurrent()
        assertEquals(listOf("record-start"), b.wire)
        b.advance(3.seconds)
        runCurrent()
        assertEquals(listOf(b.id), finished)
    }

    @Test
    fun borrowAndReturnDoesNotCloseItsOwner() = runTest {
        val shell = shell()
        val fakeSession = FakeCameraSession.lunaLike()
        val member = Counted(fakeSession)
        fakeSession.cameraReportsStatus()
        var released = 0
        shell.borrow(ConnectedCamera(Values.camera, member)) { released += 1 }
        assertTrue(shell.route == ShellModel.Route.MONITOR && shell.monitor?.isBorrowed == true)
        assertEquals(member.id, shell.control.state.value.snapshot?.session)
        shell.open(ShellModel.Cover.SETTINGS)
        shell.close()
        shell.close()
        assertTrue(released == 1 && shell.monitor == null)
        runCurrent()
        assertTrue(member.closes.isEmpty())
        assertTrue(fakeSession.wire.isEmpty())
        assertEquals(ConnectionState.Ready, fakeSession.current.connection)
    }

    @Test
    fun sceneActivityIsReportedOncePerChange() = runTest {
        val shell = shell()
        val reports = mutableListOf<Boolean>()
        shell.onSceneActivity = { reports += it }
        shell.setSceneActive(true)
        shell.setSceneActive(false)
        shell.setSceneActive(false)
        shell.setSceneActive(true)
        shell.setSceneActive(true)
        assertEquals(listOf(false, true), reports)
    }
}
