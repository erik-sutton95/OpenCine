package com.opencapture.opencine.appkitnative

import android.view.Surface
import com.opencapture.monitorui.LiveStreamEligibility
import com.opencapture.monitorui.LiveStreamEnd
import com.opencapture.monitorui.LiveStreamKeyState
import com.opencapture.monitorui.LiveStreamPhase
import com.opencapture.monitorui.LiveStreamQualityKind
import com.opencapture.monitorui.LiveStreamWarning
import com.opencapture.opencine.streaming.FakeStreamingNative
import com.opencapture.opencine.streaming.StreamCatalog
import com.opencapture.opencine.streaming.StreamConnection
import com.opencapture.opencine.streaming.StreamConnectionEvent
import com.opencapture.opencine.streaming.StreamConnectionRoute
import com.opencapture.opencine.streaming.StreamDeviceWarning
import com.opencapture.opencine.streaming.StreamKeyStorage
import com.opencapture.opencine.streaming.StreamKeyStore
import com.opencapture.opencine.streaming.StreamMediaPacket
import com.opencapture.opencine.streaming.StreamPublisher
import com.opencapture.opencine.streaming.StreamScheduler
import com.opencapture.opencine.streaming.StreamSecretSeal
import com.opencapture.opencine.streaming.StreamVideoEncoder
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/** Runs every scheduled task at once; timers never fire unless the test calls them. */
private class ImmediateScheduler : StreamScheduler {
    override fun execute(task: () -> Unit) = task()
    override fun schedule(delayNs: Long, task: () -> Unit) = StreamScheduler.Cancellable {}
    override fun repeat(periodNs: Long, task: () -> Unit) = StreamScheduler.Cancellable {}
    override fun shutdown() = Unit
}

private class Connection : StreamConnection {
    var onEvent: (StreamConnectionEvent) -> Unit = {}
    override fun open(onEvent: (StreamConnectionEvent) -> Unit) { this.onEvent = onEvent }
    override fun write(bytes: ByteArray) = Unit
    override fun close() = Unit
}

private class Video : StreamVideoEncoder {
    override val inputSurface: Surface? = null
    override fun start(startNs: Long, output: (StreamMediaPacket) -> Unit) = Unit
    override fun setBitrate(bps: Int) = Unit
    override fun requestKeyframe() = Unit
    override fun release() = Unit
}

private class Memory : StreamKeyStorage {
    val values = mutableMapOf<String, String>()
    override fun get(name: String) = values[name]
    override fun put(name: String, value: String): Boolean { values[name] = value; return true }
    override fun remove(name: String): Boolean { values.remove(name); return true }
}

private object PlainSeal : StreamSecretSeal {
    override fun seal(secret: String): String = "s:$secret"
    override fun open(stored: String): StreamSecretSeal.Opened = StreamSecretSeal.Opened.Secret(stored.removePrefix("s:"))
}

@OptIn(ExperimentalCoroutinesApi::class)
class LiveStreamCoordinatorTest {
    private val native = FakeStreamingNative()
    private val keys = StreamKeyStore(Memory(), PlainSeal)
    private var route: StreamConnectionRoute? = StreamConnectionRoute.SHARED_WIFI
    private val connections = mutableListOf<Connection>()
    private var micDenied = false
    private var micRunning = false
    private var warningsCallback: ((Set<StreamDeviceWarning>) -> Unit)? = null
    private var source: LiveStreamSource? = LiveStreamSource(1280, 720, 30, 1)
    private val requests = mutableListOf<LiveStreamRequest>()
    private val settings = object : LiveStreamSettings {
        override var selectedServiceId: String? = null
        override var showOnMonitor: Boolean = true
        override var selectedQualityId: String? = null
    }

    private fun TestScope.coordinator() = LiveStreamCoordinator(
        catalog = StreamCatalog(native), keys = keys, settings = settings, route = { route },
        source = { source },
        publisherFactory = { request ->
            requests += request
            StreamPublisher(native, request.format, request.presetId, request.enteredServerUrl, request.streamKey,
                request.crop, null, Video(), null,
                connect = { _, _, _ -> Connection().also { connections += it } },
                clock = { 0 }, scheduler = ImmediateScheduler())
        },
        microphone = {
            object : LiveStreamMicrophone {
                override fun start(onPcm: (ShortArray, Int) -> Unit) {
                    if (micDenied) throw SecurityException("denied")
                    micRunning = true
                }
                override fun stop() { micRunning = false }
            }
        },
        deviceWatch = {
            object : LiveStreamDeviceWatch {
                override fun start(onChange: (Set<StreamDeviceWarning>) -> Unit) { warningsCallback = onChange }
                override fun stop() { warningsCallback = null }
            }
        },
        clock = { 0 },
        scope = backgroundScope,
    )

    private fun TestScope.liveCoordinator(): LiveStreamCoordinator {
        keys.save("live_key", null, "twitch")
        return coordinator().also {
            it.goLive()
            connections.last().onEvent(StreamConnectionEvent.Opened)
            runCurrent()
        }
    }

    @Test
    fun rootPillShowsOnlyWhileARunningStreamHasNoMonitorControl() = runTest(UnconfinedTestDispatcher()) {
        val idle = coordinator()
        assertFalse(idle.showsRootPill.value)
        val stream = liveCoordinator()
        assertTrue(stream.showsRootPill.value)
        stream.monitorControlsAppeared()
        assertFalse(stream.showsRootPill.value)
        stream.monitorControlsAppeared()
        stream.monitorControlsGone()
        assertFalse(stream.showsRootPill.value)
        stream.monitorControlsGone()
        assertTrue(stream.showsRootPill.value)
        stream.stop()
        assertFalse(stream.showsRootPill.value)
    }

    @Test
    fun savedKeyShowsTheControl() = runTest(UnconfinedTestDispatcher()) {
        val stream = coordinator()
        assertEquals(LiveStreamKeyState.ABSENT, stream.state.value.keyState)
        assertFalse(stream.state.value.showsControl)
        stream.saveKey("live_key")
        assertEquals(LiveStreamKeyState.SAVED, stream.state.value.keyState)
        assertTrue(stream.state.value.showsControl)
        assertEquals("720p, 30 fps, 3 Mbps", com.opencapture.monitorui.LiveStreamCopy.quality(stream.state.value.quality))
    }

    @Test
    fun customServerProblemsShowAndPlainServersWarn() = runTest(UnconfinedTestDispatcher()) {
        val stream = coordinator()
        stream.selectService("custom")
        stream.setServer("https://example.com/app")
        stream.saveKey("k")
        assertEquals("Use an rtmps:// or rtmp:// address.", stream.state.value.problem)
        stream.setServer("rtmp://example.com/app")
        assertTrue(stream.state.value.plainServer)
        stream.saveKey("k")
        assertNull(stream.state.value.problem)
        assertEquals(LiveStreamKeyState.SAVED, stream.state.value.keyState)
        assertEquals("rtmp://example.com/app", coordinator().also { it.selectService("custom") }.state.value.server)
    }

    @Test
    fun ineligibleRouteNeverStarts() = runTest(UnconfinedTestDispatcher()) {
        keys.save("live_key", null, "twitch")
        route = StreamConnectionRoute.CAMERA_WIFI
        val stream = coordinator()
        assertEquals(LiveStreamEligibility.CAMERA_WIFI, stream.state.value.eligibility)
        stream.goLive()
        assertTrue(connections.isEmpty())
        assertEquals(LiveStreamPhase.Idle, stream.state.value.phase)
        route = null
        stream.refresh()
        assertEquals(LiveStreamEligibility.NO_CAMERA, stream.state.value.eligibility)
    }

    @Test
    fun stopEndsQuietlyAndReleasesTheMicrophone() = runTest(UnconfinedTestDispatcher()) {
        val stream = liveCoordinator()
        assertEquals(LiveStreamPhase.Live, stream.state.value.phase)
        assertTrue(micRunning)
        stream.stop()
        runCurrent()
        assertEquals(LiveStreamPhase.Idle, stream.state.value.phase)
        assertNull(stream.state.value.notice)
        assertFalse(micRunning)
    }

    @Test
    fun backgroundEndsTheStreamAndOffersRestart() = runTest(UnconfinedTestDispatcher()) {
        val stream = liveCoordinator()
        stream.onBackground()
        runCurrent()
        assertEquals(LiveStreamPhase.Ended(LiveStreamEnd.Background), stream.state.value.phase)
        assertEquals("The stream ended when the app left the screen.", stream.state.value.notice)
        native.phase = com.opencapture.opencine.streaming.StreamPhase.Connecting
        stream.restart()
        assertEquals(2, connections.size)
        assertEquals(LiveStreamPhase.Connecting, stream.state.value.phase)
    }

    @Test
    fun refusalShowsTheReason() = runTest(UnconfinedTestDispatcher()) {
        native.refuseWith = "Invalid key"
        val stream = liveCoordinator()
        assertEquals(LiveStreamPhase.Ended(LiveStreamEnd.Refused("Invalid key")), stream.state.value.phase)
        stream.dismissNotice()
        assertEquals(LiveStreamPhase.Idle, stream.state.value.phase)
    }

    @Test
    fun deniedMicrophoneNeverConnects() = runTest(UnconfinedTestDispatcher()) {
        micDenied = true
        keys.save("live_key", null, "twitch")
        val stream = coordinator()
        stream.goLive()
        assertTrue(connections.isEmpty())
        assertEquals(LiveStreamPhase.Ended(LiveStreamEnd.MicrophoneDenied), stream.state.value.phase)
    }

    @Test
    fun warningsNeverStopTheStream() = runTest(UnconfinedTestDispatcher()) {
        val stream = liveCoordinator()
        warningsCallback!!(setOf(StreamDeviceWarning.CRITICAL_HEAT, StreamDeviceWarning.LOW_BATTERY))
        runCurrent()
        assertEquals(setOf(LiveStreamWarning.HOT, LiveStreamWarning.LOW_BATTERY), stream.state.value.warnings)
        assertEquals(LiveStreamPhase.Live, stream.state.value.phase)
    }

    @Test
    fun settingsLockWhileRunning() = runTest(UnconfinedTestDispatcher()) {
        val stream = liveCoordinator()
        stream.selectService("custom")
        stream.removeKey()
        assertEquals("twitch", stream.state.value.selected?.id)
        assertEquals(LiveStreamKeyState.SAVED, stream.state.value.keyState)
    }

    @Test
    fun upscaledChoiceStreams1920x1080() = runTest(UnconfinedTestDispatcher()) {
        keys.save("live_key", null, "twitch")
        val stream = coordinator()
        assertEquals(listOf("cameraFeed", "upscaled1080p"), stream.state.value.qualityOptions.map { it.id })
        assertEquals("cameraFeed", stream.state.value.selectedQualityId)
        stream.selectQuality("upscaled1080p")
        val quality = stream.state.value.quality!!
        assertEquals(LiveStreamQualityKind.UPSCALED, quality.kind)
        assertEquals(1920, quality.width)
        assertEquals("upscaled1080p", settings.selectedQualityId)
        stream.goLive()
        assertEquals(1920, requests.last().format.width)
        assertEquals("upscaled1080p", native.lastChoice)
    }

    @Test
    fun rememberedChoiceFallsBackWhenNotOffered() = runTest(UnconfinedTestDispatcher()) {
        keys.save("live_key", null, "twitch")
        val stream = coordinator()
        stream.selectQuality("upscaled1080p")
        source = LiveStreamSource(1920, 1080, 30, 1)
        stream.refresh()
        assertEquals(listOf("cameraFeed"), stream.state.value.qualityOptions.map { it.id })
        assertEquals("cameraFeed", stream.state.value.selectedQualityId)
        assertEquals(LiveStreamQualityKind.SOURCE, stream.state.value.quality?.kind)
        stream.goLive()
        assertEquals("cameraFeed", native.lastChoice)
        stream.stop()
        source = LiveStreamSource(1280, 720, null, null)
        val again = coordinator()
        assertEquals("upscaled1080p", again.state.value.selectedQualityId)
        again.selectQuality("nope")
        assertEquals("upscaled1080p", again.state.value.selectedQualityId)
    }

    /** Android keeps 1080p from camera hidden until its hardware pass: never listed, never streamed. */
    @Test
    fun cameraChoiceIsNeverOfferedOnAndroidYet() = runTest(UnconfinedTestDispatcher()) {
        keys.save("live_key", null, "twitch")
        val stream = coordinator()
        stream.selectQuality("camera1080p")
        assertEquals(listOf("cameraFeed", "upscaled1080p"), stream.state.value.qualityOptions.map { it.id })
        assertEquals("cameraFeed", stream.state.value.selectedQualityId)
        stream.goLive()
        assertEquals("cameraFeed", native.lastChoice)
    }

    @Test
    fun qualityIsLockedWhileLive() = runTest(UnconfinedTestDispatcher()) {
        val stream = liveCoordinator()
        stream.selectQuality("upscaled1080p")
        assertEquals("cameraFeed", stream.state.value.selectedQualityId)
        assertEquals(1280, stream.state.value.quality?.width)
    }

    @Test
    fun aRunningStreamKeepsItsQualityUntilItStops() = runTest(UnconfinedTestDispatcher()) {
        keys.save("live_key", null, "twitch")
        val stream = coordinator()
        stream.selectQuality("upscaled1080p")
        stream.goLive()
        connections.last().onEvent(StreamConnectionEvent.Opened)
        runCurrent()
        source = LiveStreamSource(1920, 1080, 30, 1)
        stream.refresh()
        assertEquals(LiveStreamQualityKind.UPSCALED, stream.state.value.quality?.kind)
        assertEquals("upscaled1080p", stream.state.value.selectedQualityId)
        stream.stop()
        assertEquals(LiveStreamQualityKind.SOURCE, stream.state.value.quality?.kind)
        assertEquals("cameraFeed", stream.state.value.selectedQualityId)
    }
}
