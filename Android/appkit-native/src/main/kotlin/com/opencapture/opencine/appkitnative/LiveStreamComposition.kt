package com.opencapture.opencine.appkitnative

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import android.view.Surface
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
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
 * The Go live control, status, notice and warnings at the top center of the live picture.
 * Confirming a start asks for the microphone first when the app does not hold it yet; a refusal
 * ends with the microphone notice.
 */
@Composable
fun MonitorLiveFeedScope.LiveStreamOverlay(coordinator: LiveStreamCoordinator) {
    val state by coordinator.state.collectAsState()
    val context = androidx.compose.ui.platform.LocalContext.current
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        coordinator.goLive()
    }
    val feed = geometry.layout.onFeed
    Box(Modifier.offset(feed.x.dp, feed.y.dp).size(feed.width.dp, feed.height.dp)) {
        LiveStreamMonitorControls(state, coordinator, Modifier.align(Alignment.TopCenter).padding(top = 10.dp)) {
            val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
            if (granted) coordinator.goLive() else permission.launch(Manifest.permission.RECORD_AUDIO)
        }
    }
}
