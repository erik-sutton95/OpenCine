package com.opencapture.opencine.appkitnative

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import android.view.Surface
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.opencapture.monitorui.isRunning
import com.opencapture.monitorui.livestream.LiveStreamMonitorControls
import com.opencapture.monitorui.livestream.LiveStreamRootPill
import com.opencapture.opencine.appkit.rememberPermissionGate
import com.opencapture.opencine.runtime.MonitorCleanPictureFill
import com.opencapture.opencine.runtime.MonitorCleanPictureTap
import com.opencapture.opencine.streaming.AacStreamEncoder
import com.opencapture.opencine.streaming.H264StreamEncoder
import com.opencapture.opencine.streaming.StreamCatalog
import com.opencapture.opencine.streaming.StreamConnectionRoute
import com.opencapture.opencine.streaming.StreamDeviceMonitor
import com.opencapture.opencine.streaming.StreamDeviceWarning
import com.opencapture.opencine.streaming.StreamKeyStore
import com.opencapture.opencine.streaming.StreamMicrophone
import com.opencapture.opencine.streaming.StreamPictureSource
import com.opencapture.opencine.streaming.StreamPublisher
import com.opencapture.opencine.streaming.StreamingNative
import com.opencapture.opencine.streaming.StreamingNativeApi
import kotlinx.coroutines.CoroutineScope

/** The native runtime's clean picture as the stream's picture source. */
class MonitorCleanPictureStreamSource(private val tap: MonitorCleanPictureTap) : StreamPictureSource {
    override fun attach(surface: Surface, width: Int, height: Int, crop: Boolean, onPicture: () -> Unit) {
        tap.attach(surface, width, height, if (crop) MonitorCleanPictureFill.CROP else MonitorCleanPictureFill.FIT,
            onPicture = { onPicture() },
            // The stream continues on the slate; the monitor is untouched.
            onFailed = { error -> Log.w("OpenCineStream", "clean picture stopped", error) })
    }

    override fun draw(presentationTimeNs: Long, slate: Boolean) = tap.draw(presentationTimeNs, slate)

    override fun detach() = tap.detach()
}

/** App-private preferences for the operator's non-secret choices. */
private class PreferencesLiveStreamSettings(context: Context, file: String) : LiveStreamSettings {
    private val preferences = context.applicationContext.getSharedPreferences(file, Context.MODE_PRIVATE)
    override var selectedServiceId: String?
        get() = preferences.getString("live-stream.service", null)
        set(value) { preferences.edit().putString("live-stream.service", value).apply() }
    override var showOnMonitor: Boolean
        get() = preferences.getBoolean("live-stream.show-on-monitor", true)
        set(value) { preferences.edit().putBoolean("live-stream.show-on-monitor", value).apply() }
}

/** Builds an app's live stream coordinator. Every argument but the context is a host value. */
object LiveStreamComposition {
    /**
     * [preferencesFile] and [keystoreAlias] name the app's own storage (for example
     * `<applicationId>.live-stream`); [cleanPicture] is the tap the live feed integration feeds.
     * [route] and [source] read the app's current connection mode and selected camera.
     * The app has loaded its Swift library into [native] before calling.
     */
    fun coordinator(
        context: Context,
        preferencesFile: String,
        keystoreAlias: String,
        cleanPicture: MonitorCleanPictureTap?,
        route: () -> StreamConnectionRoute?,
        source: () -> LiveStreamSource?,
        scope: CoroutineScope,
        native: StreamingNativeApi = StreamingNative,
    ): LiveStreamCoordinator {
        val app = context.applicationContext
        val picture = cleanPicture?.let(::MonitorCleanPictureStreamSource)
        return LiveStreamCoordinator(
            catalog = StreamCatalog(native),
            keys = StreamKeyStore.create(app, preferencesFile, keystoreAlias),
            settings = PreferencesLiveStreamSettings(app, preferencesFile),
            route = route,
            source = source,
            publisherFactory = { request ->
                val video = H264StreamEncoder(request.format)
                val audio = runCatching { AacStreamEncoder(request.format) }.getOrNull()
                StreamPublisher(native, request.format, request.presetId, request.enteredServerUrl,
                    request.streamKey, request.crop, picture, video, audio)
            },
            microphone = {
                val granted = ContextCompat.checkSelfPermission(app, Manifest.permission.RECORD_AUDIO) ==
                    PackageManager.PERMISSION_GRANTED
                val capture = StreamMicrophone()
                object : LiveStreamMicrophone {
                    override fun start(onPcm: (ShortArray, Int) -> Unit) {
                        if (!granted) throw SecurityException("microphone permission denied")
                        capture.start(onPcm)
                    }

                    override fun stop() = capture.stop()
                }
            },
            deviceWatch = {
                val monitor = StreamDeviceMonitor(app, ContextCompat.getMainExecutor(app))
                object : LiveStreamDeviceWatch {
                    override fun start(onChange: (Set<StreamDeviceWarning>) -> Unit) = monitor.start(onChange)
                    override fun stop() = monitor.stop()
                }
            },
            clock = System::nanoTime,
            scope = scope,
            permissionPreferences = "$preferencesFile.permissions",
        )
    }
}

/**
 * The host rules every app gets with streaming: the screen stays awake while a stream runs, and
 * leaving the screen (the activity stops) ends a running stream with a restart offer.
 */
@Composable
fun LiveStreamHostEffects(coordinator: LiveStreamCoordinator) {
    val state by coordinator.state.collectAsState()
    val view = LocalView.current
    val running = state.phase.isRunning
    DisposableEffect(view, running) {
        view.keepScreenOn = running
        onDispose { view.keepScreenOn = false }
    }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val current by rememberUpdatedState(coordinator)
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) current.onBackground() }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
}

/**
 * The Go live control, status, notice and warnings, aligned to the top center of [modifier]'s box
 * (an app places that box over its monitor picture). Confirming a start asks for the microphone
 * through the shared permission gate when the app does not hold it yet: the start runs once it is
 * granted; a refusal still goes through the coordinator, which ends with the microphone notice.
 */
@Composable
fun LiveStreamOverlay(coordinator: LiveStreamCoordinator, modifier: Modifier = Modifier) {
    val state by coordinator.state.collectAsState()
    var startWhenGranted by remember { mutableStateOf(false) }
    val microphone = rememberPermissionGate(
        label = "livestream.microphone",
        needed = listOf(Manifest.permission.RECORD_AUDIO),
        preferencesName = coordinator.permissionPreferences,
        log = { line -> Log.i("OpenCineStream", line) },
    ) {
        if (startWhenGranted) {
            startWhenGranted = false
            coordinator.goLive()
        }
    }
    // The system dialog returns on resume, after the gate's own observer (registered first). A
    // start still waiting then was refused: the coordinator shows the microphone notice.
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, coordinator) {
        val observer = LifecycleEventObserver { _, event ->
            if (event != Lifecycle.Event.ON_RESUME || !startWhenGranted) return@LifecycleEventObserver
            startWhenGranted = false
            coordinator.goLive()
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    // While this overlay is on screen the root pill stays hidden: the monitor shows the stream.
    DisposableEffect(coordinator) {
        coordinator.monitorControlsAppeared()
        onDispose { coordinator.monitorControlsGone() }
    }
    Box(modifier) {
        LiveStreamMonitorControls(state, coordinator, Modifier.align(Alignment.TopCenter).padding(top = 10.dp)) {
            if (microphone.granted) {
                coordinator.goLive()
            } else {
                startWhenGranted = true
                microphone.request()
            }
        }
    }
}

/** [LiveStreamOverlay] over the shared live host's picture. */
@Composable
fun MonitorLiveFeedScope.LiveStreamOverlay(coordinator: LiveStreamCoordinator) {
    val feed = geometry.layout.onFeed
    LiveStreamOverlay(coordinator, Modifier.offset(feed.x.dp, feed.y.dp).size(feed.width.dp, feed.height.dp))
}

/**
 * The root-level Live pill (elapsed time and Stop) for wherever a running stream outlives the
 * monitor screen. Place it once at the app root, above every stage: it draws only while a stream
 * runs and no [LiveStreamOverlay] is on screen.
 */
@Composable
fun LiveStreamRootIndicator(coordinator: LiveStreamCoordinator, modifier: Modifier = Modifier) {
    val state by coordinator.state.collectAsState()
    val shows by coordinator.showsRootPill.collectAsState()
    if (shows) LiveStreamRootPill(state, coordinator, modifier)
}
