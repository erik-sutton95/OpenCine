package com.opencapture.opencine.appkitnative

import com.opencapture.monitorui.LiveStreamActions
import com.opencapture.monitorui.LiveStreamCopy
import com.opencapture.monitorui.LiveStreamEligibility
import com.opencapture.monitorui.LiveStreamEnd
import com.opencapture.monitorui.LiveStreamHealth
import com.opencapture.monitorui.LiveStreamKeyState
import com.opencapture.monitorui.LiveStreamPhase
import com.opencapture.monitorui.LiveStreamQuality
import com.opencapture.monitorui.LiveStreamServiceOption
import com.opencapture.monitorui.LiveStreamState
import com.opencapture.monitorui.LiveStreamStatusState
import com.opencapture.monitorui.LiveStreamWarning
import com.opencapture.monitorui.isRunning
import com.opencapture.opencine.streaming.StreamCatalog
import com.opencapture.opencine.streaming.StreamConnectionRoute
import com.opencapture.opencine.streaming.StreamDestinationCheck
import com.opencapture.opencine.streaming.StreamDestinationProblem
import com.opencapture.opencine.streaming.StreamDeviceWarning
import com.opencapture.opencine.streaming.StreamEnd
import com.opencapture.opencine.streaming.StreamHealth
import com.opencapture.opencine.streaming.StreamKeyStore
import com.opencapture.opencine.streaming.StreamOutputFormat
import com.opencapture.opencine.streaming.StreamPhase
import com.opencapture.opencine.streaming.StreamPublisher
import com.opencapture.opencine.streaming.StreamServicePreset
import com.opencapture.opencine.streaming.StreamStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** The selected camera's real picture, as the app knows it; a null rate means unstated. */
data class LiveStreamSource(val width: Int, val height: Int, val fpsNum: Int?, val fpsDen: Int?)

/** What one stream needs from the composition, handed to the publisher factory. */
class LiveStreamRequest(
    val format: StreamOutputFormat,
    val presetId: String,
    /** The saved server for a preset that asks for one; empty otherwise. */
    val enteredServerUrl: String,
    val streamKey: String,
    /** Center crop to fill (the vertical preset) instead of fitting with bars. */
    val crop: Boolean,
) {
    override fun toString(): String = "LiveStreamRequest(${format.width}x${format.height})"
}

/** The operator's non-secret live stream choices; production is app-private preferences. */
interface LiveStreamSettings {
    var selectedServiceId: String?
    var showOnMonitor: Boolean
}

/** The microphone while live. [start] throws when it cannot capture (permission denied). */
interface LiveStreamMicrophone {
    fun start(onPcm: (ShortArray, Int) -> Unit)

    fun stop()
}

/** Heat and battery while live; never stops a stream. */
interface LiveStreamDeviceWatch {
    fun start(onChange: (Set<StreamDeviceWarning>) -> Unit)

    fun stop()
}

/**
 * One app's live streaming: the settings card's values, the Go live control and the stream
 * itself (Android twin of the iOS composition). App differences arrive through [route] and
 * [source]; the coordinator never sends a camera command, and a stream failure never reaches the
 * monitor or camera control.
 *
 * Foreground only: [onBackground] ends a running stream and the notice offers a restart.
 * The screen stays awake while a stream runs (`LiveStreamHostEffects`). Heat and low battery warn
 * and never stop the stream.
 */
class LiveStreamCoordinator(
    private val catalog: StreamCatalog,
    private val keys: StreamKeyStore,
    private val settings: LiveStreamSettings,
    private val route: () -> StreamConnectionRoute?,
    private val source: () -> LiveStreamSource?,
    private val publisherFactory: (LiveStreamRequest) -> StreamPublisher,
    private val microphone: () -> LiveStreamMicrophone?,
    private val deviceWatch: () -> LiveStreamDeviceWatch?,
    private val clock: () -> Long,
    private val scope: CoroutineScope,
    /** The app's preferences file where the microphone ask remembers a refusal. */
    val permissionPreferences: String = "opencine.live-stream.permissions",
) : LiveStreamActions {
    private val presets: List<StreamServicePreset> = catalog.presets()
    private val mutableState = MutableStateFlow(LiveStreamState())
    val state: StateFlow<LiveStreamState> = mutableState.asStateFlow()

    private val monitorControls = MutableStateFlow(0)

    /**
     * The root Live pill is due: a stream runs and no monitor shows its Go live control (the
     * monitor closed, another stage covers it).
     */
    val showsRootPill: StateFlow<Boolean> = combine(mutableState, monitorControls) { state, controls ->
        state.phase.isRunning && controls == 0
    }.stateIn(scope, SharingStarted.Eagerly, false)

    /** A monitor overlay with the Go live control came on screen; pair with [monitorControlsGone]. */
    fun monitorControlsAppeared() = monitorControls.update { it + 1 }

    /** A monitor overlay from [monitorControlsAppeared] left the screen. */
    fun monitorControlsGone() = monitorControls.update { (it - 1).coerceAtLeast(0) }

    private var publisher: StreamPublisher? = null
    private var activeMicrophone: LiveStreamMicrophone? = null
    private var activeWatch: LiveStreamDeviceWatch? = null
    private var statusJob: Job? = null
    private var endedByBackground = false
    private var latestStatus: StreamStatus? = null

    init {
        val services = presets.map { it.option() }
        val selected = settings.selectedServiceId?.takeIf { id -> services.any { it.id == id } } ?: services.firstOrNull()?.id
        mutableState.value = LiveStreamState(services = services, selectedServiceId = selected,
            showOnMonitor = settings.showOnMonitor)
        refresh()
    }

    /** Re-reads the route, the source and the saved key; call when the camera link changes. */
    fun refresh() {
        val preset = selectedPreset()
        val camera = source()
        mutableState.update { state ->
            if (preset == null) return@update state
            val saved = keys.key(preset.id)
            val server = if (preset.requiresServerEntry) {
                (keys.server(preset.id) as? StreamKeyStore.Lookup.Stored)?.value ?: state.server.takeIf {
                    saved !is StreamKeyStore.Lookup.Stored
                }.orEmpty()
            } else {
                ""
            }
            state.copy(
                server = server,
                keyState = when (saved) {
                    StreamKeyStore.Lookup.Absent -> LiveStreamKeyState.ABSENT
                    is StreamKeyStore.Lookup.Stored -> LiveStreamKeyState.SAVED
                    StreamKeyStore.Lookup.Unavailable -> LiveStreamKeyState.UNAVAILABLE
                },
                quality = camera?.let { format(preset, it) }?.quality(),
                sourceHeight = camera?.height,
                eligibility = eligibility(),
            )
        }
    }

    // MARK: Settings

    override fun selectService(id: String) {
        if (state.value.phase.isRunning || presets.none { it.id == id }) return
        settings.selectedServiceId = id
        mutableState.update { it.copy(selectedServiceId = id, server = "", problem = null) }
        refresh()
    }

    override fun setServer(text: String) {
        if (state.value.phase.isRunning) return
        mutableState.update { it.copy(server = text, problem = null) }
    }

    override fun saveKey(key: String) {
        val preset = selectedPreset() ?: return
        if (state.value.phase.isRunning || state.value.keyState == LiveStreamKeyState.UNAVAILABLE) return
        val server = if (preset.requiresServerEntry) state.value.server.trim() else ""
        when (val check = catalog.check(preset.id, server, key)) {
            is StreamDestinationCheck.Invalid -> mutableState.update {
                it.copy(problem = LiveStreamCopy.problem(check.problem.wireName(), custom = preset.allowsPlainRtmp))
            }
            is StreamDestinationCheck.Ok -> {
                val saved = keys.save(key.trim(), server.takeIf { preset.requiresServerEntry }, preset.id)
                mutableState.update { it.copy(problem = null) }
                if (saved) refresh() else mutableState.update { it.copy(keyState = LiveStreamKeyState.UNAVAILABLE) }
            }
        }
    }

    override fun removeKey() {
        val preset = selectedPreset() ?: return
        if (state.value.phase.isRunning) return
        keys.remove(preset.id)
        mutableState.update { it.copy(server = "") }
        refresh()
    }

    override fun setShowOnMonitor(show: Boolean) {
        settings.showOnMonitor = show
        mutableState.update { it.copy(showOnMonitor = show) }
    }

    // MARK: The stream

    override fun goLive() {
        if (state.value.phase.isRunning) return
        refresh()
        val preset = selectedPreset() ?: return
        if (state.value.eligibility != LiveStreamEligibility.ALLOWED) return
        val key = (keys.key(preset.id) as? StreamKeyStore.Lookup.Stored)?.value ?: return
        val server = if (preset.requiresServerEntry) {
            (keys.server(preset.id) as? StreamKeyStore.Lookup.Stored)?.value ?: return
        } else {
            ""
        }
        val camera = source() ?: LiveStreamSource(1280, 720, null, null)
        val output = format(preset, camera) ?: return
        endedByBackground = false
        latestStatus = null
        val mic = microphone()
        val stream = try {
            publisherFactory(LiveStreamRequest(output, preset.id, server, key, crop = preset.portrait))
        } catch (error: Exception) {
            // A device without a usable encoder: nothing started, nothing to end.
            runCatching { android.util.Log.w("OpenCineStream", "stream did not start", error) }
            return
        }
        if (mic != null) {
            try {
                mic.start { pcm, frames -> stream.submitAudio(pcm, frames) }
            } catch (_: Exception) {
                end(LiveStreamEnd.MicrophoneDenied)
                return
            }
        }
        activeMicrophone = mic
        if (stream.start() is StreamDestinationCheck.Invalid) {
            mic?.stop()
            activeMicrophone = null
            end(LiveStreamEnd.Unreachable)
            return
        }
        publisher = stream
        mutableState.update { it.copy(phase = LiveStreamPhase.Connecting, status = null, warnings = emptySet()) }
        activeWatch = deviceWatch()?.also { watch ->
            watch.start { warnings -> scope.launch { mutableState.update { it.copy(warnings = warnings.ui()) } } }
        }
        statusJob = scope.launch {
            launch { stream.status.collect { status -> onStatus(status) } }
            while (true) {
                delay(1_000)
                latestStatus?.let { onStatus(it) }
            }
        }
    }

    override fun stop() {
        publisher?.stop()
    }

    override fun restart() {
        if (state.value.phase !is LiveStreamPhase.Ended) return
        goLive()
    }

    override fun dismissNotice() {
        if (state.value.phase is LiveStreamPhase.Ended) mutableState.update { it.copy(phase = LiveStreamPhase.Idle) }
    }

    /** The app left the screen: a running stream ends and the notice offers a restart. */
    fun onBackground() {
        if (!state.value.phase.isRunning) return
        endedByBackground = true
        publisher?.stop()
    }

    private fun onStatus(status: StreamStatus) {
        latestStatus = status
        when (val phase = status.phase) {
            is StreamPhase.Ended -> {
                val end = when (val reason = phase.end) {
                    StreamEnd.Stopped -> if (endedByBackground) LiveStreamEnd.Background else LiveStreamEnd.Stopped
                    is StreamEnd.Refused -> LiveStreamEnd.Refused(reason.reason)
                    StreamEnd.GaveUp -> if (status.liveSinceNs == null) LiveStreamEnd.Unreachable else LiveStreamEnd.GaveUp
                }
                end(end)
            }
            else -> mutableState.update {
                it.copy(
                    phase = when (phase) {
                        StreamPhase.Connecting -> LiveStreamPhase.Connecting
                        StreamPhase.Live -> LiveStreamPhase.Live
                        is StreamPhase.Reconnecting -> LiveStreamPhase.Reconnecting(phase.attempt)
                        else -> it.phase
                    },
                    status = LiveStreamStatusState(
                        phase = it.phase,
                        elapsedSeconds = status.liveSinceNs?.let { since -> ((clock() - since) / 1_000_000_000).toInt() } ?: 0,
                        sentBitrateBps = status.sentBitrateBps,
                        droppedGroups = status.droppedVideoGroups,
                        health = when (status.health) {
                            StreamHealth.GOOD -> LiveStreamHealth.GOOD
                            StreamHealth.CONGESTED -> LiveStreamHealth.CONGESTED
                            StreamHealth.OFFLINE -> LiveStreamHealth.OFFLINE
                        },
                    ),
                ).let { next -> next.copy(status = next.status?.copy(phase = next.phase)) }
            }
        }
    }

    /** Ends the stream's resources and shows [end]. */
    private fun end(end: LiveStreamEnd) {
        val job = statusJob
        statusJob = null
        publisher = null
        latestStatus = null
        activeMicrophone?.stop()
        activeMicrophone = null
        activeWatch?.stop()
        activeWatch = null
        mutableState.update {
            it.copy(
                phase = if (end == LiveStreamEnd.Stopped) LiveStreamPhase.Idle else LiveStreamPhase.Ended(end),
                status = null,
                warnings = emptySet(),
            )
        }
        job?.cancel()
    }

    private fun selectedPreset(): StreamServicePreset? =
        presets.firstOrNull { it.id == state.value.selectedServiceId } ?: presets.firstOrNull()

    private fun eligibility(): LiveStreamEligibility {
        val current = route() ?: return LiveStreamEligibility.NO_CAMERA
        return when {
            catalog.canStream(current) -> LiveStreamEligibility.ALLOWED
            current == StreamConnectionRoute.CAMERA_WIFI -> LiveStreamEligibility.CAMERA_WIFI
            else -> LiveStreamEligibility.NO_CAMERA
        }
    }

    private fun format(preset: StreamServicePreset, camera: LiveStreamSource): StreamOutputFormat? =
        catalog.format(preset.id, camera.width, camera.height, camera.fpsNum, camera.fpsDen)

    private fun StreamOutputFormat.quality() =
        LiveStreamQuality(width, height, framesPerSecond, videoBitrateBps)

    private fun StreamServicePreset.option() = LiveStreamServiceOption(
        id = id, name = displayName, keyHint = keyHint, needsServer = requiresServerEntry,
        acceptsPlainServer = allowsPlainRtmp, vertical = portrait,
    )

    private fun Set<StreamDeviceWarning>.ui(): Set<LiveStreamWarning> = mapNotNull {
        when (it) {
            StreamDeviceWarning.HOT, StreamDeviceWarning.CRITICAL_HEAT -> LiveStreamWarning.HOT
            StreamDeviceWarning.LOW_BATTERY -> LiveStreamWarning.LOW_BATTERY
        }
    }.toSet()

    private fun StreamDestinationProblem.wireName(): String = when (this) {
        StreamDestinationProblem.NOT_RTMPS -> "notRTMPS"
        StreamDestinationProblem.EMPTY_KEY -> "emptyKey"
        StreamDestinationProblem.KEY_LOOKS_LIKE_URL -> "keyLooksLikeURL"
        StreamDestinationProblem.INVALID_SERVER_URL, StreamDestinationProblem.INVALID_FORMAT,
        StreamDestinationProblem.UNKNOWN_PRESET -> "invalidServerURL"
    }
}
