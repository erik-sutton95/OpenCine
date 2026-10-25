package com.opencapture.opencine.dji

import com.opencapture.opencine.platform.withCredentialIO
import com.opencapture.opencine.core.CameraValuePin
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.media.RecoveryAction
import com.opencapture.opencine.media.RecoveryEffect
import com.opencapture.opencine.media.RecoveryReason
import com.opencapture.opencine.media.RecoveryEffectLog
import com.opencapture.opencine.media.FeedIncidentAges
import com.opencapture.opencine.media.FeedIncidentBreadcrumb
import com.opencapture.opencine.media.FeedIncidentBreadcrumbKind
import com.opencapture.opencine.media.FeedIncidentLifecycle
import com.opencapture.opencine.media.FeedIncidentQueue
import com.opencapture.opencine.media.FeedIncidentRateObservation
import com.opencapture.opencine.media.FeedIncidentRateSampler
import com.opencapture.opencine.decoder.incidentDecoder
import com.opencapture.opencine.media.FeedIncidentSource
import com.opencapture.opencine.media.FeedIncidentSnapshot
import com.opencapture.opencine.media.FeedIncidentThermal
import com.opencapture.opencine.media.FeedIncidentWatchdogGate
import com.opencapture.opencine.media.FeedRepairPhase
import com.opencapture.opencine.media.FeedRepairRecord
import android.content.Context
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import com.opencapture.opencine.media.HostShutterPresentation
import com.opencapture.opencine.media.SerialSessionGate
import com.opencapture.opencine.decoder.HevcDecoder
import android.os.Build
import com.opencapture.opencine.motion.GimbalProgram
import com.opencapture.opencine.motion.GimbalWaypoint
import com.opencapture.opencine.motion.GimbalWaypointSlot
import com.opencapture.opencine.motion.LevelReading
import com.opencapture.opencine.motion.SnapOutcome
import com.opencapture.opencine.motion.WorldLevelSnap
import com.opencapture.opencine.platform.LocalVPNProbe
import com.opencapture.opencine.platform.WifiLowLatencyLock
import com.opencapture.opencine.vocabulary.AudioPin
import com.opencapture.opencine.vocabulary.AutoExposureLock
import com.opencapture.opencine.vocabulary.CamFov
import com.opencapture.opencine.vocabulary.CaptureWheels
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraFocusPolicy
import com.opencapture.opencine.vocabulary.CameraModel
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.CaptureShutterPolicy
import com.opencapture.opencine.vocabulary.ColorPin
import com.opencapture.opencine.vocabulary.ConnectionPhase
import com.opencapture.opencine.vocabulary.ControlHud
import com.opencapture.opencine.vocabulary.EvComp
import com.opencapture.opencine.vocabulary.ExpoPin
import com.opencapture.opencine.vocabulary.FaceAFPolicy
import com.opencapture.opencine.vocabulary.FacePriorityExposure
import com.opencapture.opencine.vocabulary.FaceTrackHold
import com.opencapture.opencine.vocabulary.FaceTrackTap
import com.opencapture.opencine.vocabulary.FeedDoubleTapTrack
import com.opencapture.opencine.vocabulary.FocusOverlay
import com.opencapture.opencine.vocabulary.FocusOverlayPolicy
import com.opencapture.opencine.vocabulary.FocusPin
import com.opencapture.opencine.vocabulary.FocusResetPolicy
import com.opencapture.opencine.vocabulary.FocusTrackMode
import com.opencapture.opencine.vocabulary.FormatPin
import com.opencapture.opencine.vocabulary.FoundCamera
import com.opencapture.opencine.vocabulary.GamepadFaceTrack
import com.opencapture.opencine.vocabulary.GamepadOperatorAction
import com.opencapture.opencine.vocabulary.GamepadShutterSync
import com.opencapture.opencine.vocabulary.GimbalDoubleTap
import com.opencapture.opencine.vocabulary.GimbalHudCopy
import com.opencapture.opencine.vocabulary.GimbalLimitContact
import com.opencapture.opencine.vocabulary.GimbalLimitWatch
import com.opencapture.opencine.vocabulary.GimbalMode
import com.opencapture.opencine.vocabulary.GimbalRamp
import com.opencapture.opencine.vocabulary.GimbalSpeed
import com.opencapture.opencine.vocabulary.GimbalStickMapping
import com.opencapture.opencine.vocabulary.IsoLimitPin
import com.opencapture.opencine.vocabulary.LiveChromeThrottle
import com.opencapture.opencine.vocabulary.LiveFeedTapPolicy
import com.opencapture.opencine.vocabulary.RecoveryPictureProof
import com.opencapture.opencine.vocabulary.SceneFacePolicy
import com.opencapture.opencine.vocabulary.SessionRecoveryEpisode
import com.opencapture.opencine.vocabulary.SessionRecoveryPolicy
import com.opencapture.opencine.vocabulary.SessionRecoveryTrigger
import com.opencapture.opencine.vocabulary.SessionRecoveryUi
import com.opencapture.opencine.vocabulary.ShootingModePin
import com.opencapture.opencine.vocabulary.ShutterAngle
import com.opencapture.opencine.vocabulary.TrackingBox
import com.opencapture.opencine.vocabulary.TrackingBoxSmoothing
import com.opencapture.opencine.vocabulary.TrackingClearPolicy
import com.opencapture.opencine.vocabulary.TrackingHud
import com.opencapture.opencine.vocabulary.TrackingStartPolicy
import com.opencapture.opencine.vocabulary.VideoFormat
import com.opencapture.opencine.vocabulary.WhiteBalancePin
import java.util.UUID
import kotlinx.coroutines.cancel
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import com.opencapture.opencine.media.CameraMediaService
import com.opencapture.opencine.media.MediaServiceException
import com.opencapture.opencine.media.MediaServiceFailure
import com.opencapture.opencine.core.CameraServices
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeout
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.Continuation
import kotlin.coroutines.coroutineContext
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.math.abs
import kotlin.math.hypot
import java.util.Locale
import org.json.JSONObject
import com.opencapture.opencine.media.DecoderErrorOrigin
import com.opencapture.opencine.media.DecoderInputOwnership
import com.opencapture.opencine.media.EncoderPresentPath
import com.opencapture.opencine.media.LivePipelineCadence

/** Main-thread admission closes before negotiation is dispatched to the IO worker. */
internal class EndpointCommandAdmission {
    private var owner: Any? = null

    fun begin(): Any = Any().also { owner = it }

    fun finish(token: Any) {
        if (owner === token) owner = null
    }

    fun allows(isClosed: Boolean, isRebuilding: Boolean): Boolean =
        owner == null && !isClosed && !isRebuilding
}

/** Keep blocking negotiation and its post-handshake enable owned by the same live link. */
internal suspend fun <T : Any> repairDatalinkEndpoint(
    link: T,
    isCurrent: (T) -> Boolean,
    reopen: (T) -> Unit,
    pictureTimeoutMs: Long = LiveViewEnablePolicy.ENDPOINT_PICTURE_GRACE_MS,
    waitForPicture: suspend () -> Unit = {},
    recoverSession: () -> Unit = {},
    commandAdmission: EndpointCommandAdmission = EndpointCommandAdmission(),
    prepare: () -> Unit = {},
    ownsPicture: () -> Boolean = { true },
    enable: () -> Unit,
) {
    val commandOwner = commandAdmission.begin()
    var negotiated = false
    try {
        prepare()
        interruptibleDatalinkOpen { reopen(link) }
        negotiated = true
        coroutineContext.ensureActive()
        if (!isCurrent(link)) return
        commandAdmission.finish(commandOwner)
        if (!ownsPicture()) return
        enable()
        val presented = kotlinx.coroutines.withTimeoutOrNull(pictureTimeoutMs) {
            waitForPicture()
            true
        } ?: false
        coroutineContext.ensureActive()
        if (!presented && isCurrent(link) && ownsPicture()) recoverSession()
    } catch (error: kotlinx.coroutines.CancellationException) {
        throw error
    } catch (_: Exception) {
        coroutineContext.ensureActive()
        if (isCurrent(link) && (!negotiated || ownsPicture())) recoverSession()
    } finally {
        commandAdmission.finish(commandOwner)
    }
}

internal fun acceptsGimbalConfiguration(
    hasGimbal: Boolean, live: Boolean, sceneActive: Boolean, warming: Boolean,
    recovering: Boolean, videoStale: Boolean, hasDatalink: Boolean,
): Boolean = hasGimbal && live && sceneActive && !warming && !recovering && !videoStale && hasDatalink

/**
 * DJI's bound on one session-recovery attempt once the datalink handshake admits it: the first
 * fresh picture within one GOP grace. The scan, BLE pairing and Wi-Fi join before admission keep
 * their own transport deadlines inside the shared 180 s budget.
 */
internal val DJI_RECOVERY_ATTEMPT_DEADLINE =
    SessionRecoveryEpisode.AttemptDeadline(attemptMs = LiveViewEnablePolicy.GOP_GRACE_MS)

/** A serialized command chain keeps its original endpoint epoch across every suspension. */
internal class EndpointCommandEpoch(val generation: Long) :
    kotlin.coroutines.AbstractCoroutineContextElement(Key) {
    companion object Key : kotlin.coroutines.CoroutineContext.Key<EndpointCommandEpoch>
}

internal suspend fun ensureEndpointCommandCurrent(currentGeneration: Long) {
    coroutineContext.ensureActive()
    val epoch = coroutineContext[EndpointCommandEpoch]
    if (epoch != null && epoch.generation != currentGeneration) {
        throw kotlinx.coroutines.CancellationException("camera command endpoint changed")
    }
}

/**
 * BLE → pair → Wi-Fi creds → camera AP → datalink → live HEVC/AVC.
 * Mirrors iOS `CameraSession` recovery, feed watchdog, and operator commands.
 */
class PocketCameraSession(
    context: Context,
    private val appHost: PocketSessionHost,
    borrowing: HevcDecoder? = null,
    private val controlLease: MultiviewControlLease? = null,
) : PocketControlPort, DjiConnectPort {
    init { require(controlLease == null || borrowing != null) }
    val isMultiviewControlOnly: Boolean get() = controlLease != null
    private fun controlLeaseAllows(): Boolean = controlLease?.allows() != false

    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val ble = BleLink(context)
    private val joiner = DjiCameraAp.joiner(context)
    private val joinerPath = joiner.asNetworkPath()
    /** The operator's Wi-Fi or this phone's hotspot for the Wi-Fi and Hotspot setups (#406). */
    private val station = SharedWiFi(context)
    val cadence = LivePipelineCadence()
    /** Instrumentation only. Invoked after ACK observation; never blocks or delays the receive thread. */
    @Volatile var debugVideoPacketAdmission: (() -> Boolean)? = null
    /** Main-thread instrumentation observes actual ACKs/timeouts, never the optimistic HUD. */
    var debugCameraSetResult: ((Int, Boolean) -> Unit)? = null
    val pendingCameraSetCount: Int get() = inflight.size + inflightPending.size
    fun pendingCameraSetExtra(kind: Int): String? =
        inflight[DjiNative.waitKey(kind)]?.extra
            ?: inflightPending[DjiNative.waitKey(kind)]?.extra
    private val videoHistory = LiveSessionVideoHistory()
    /**
     * Multiview lends a tile's decoder and verified transport to Live View.
     * The stage stays the sole repair owner (iOS `isMultiviewBorrowed`).
     */
    val isMultiviewBorrowed = borrowing != null
    private var borrowedSurface: Surface? = null
    val decoder = borrowing ?: HevcDecoder(cadence, errorJournal = { DjiLog.log("warning", "decoder", it.origin.wire, it.journalLine()) }).also { dec ->
        dec.onParameterSetsChanged = {
            scope.launch {
                val now = SystemClock.elapsedRealtime()
                val videoAge = datalink?.lastVideoPacketAt?.let { now - it }
                val auAge = datalink?.lastAccessUnitAt?.let { now - it }
                val videoAlive =
                    (videoAge != null && videoAge < LiveViewEnablePolicy.STALL_MS) ||
                        (auAge != null && auAge < LiveViewEnablePolicy.STALL_MS)
                val since =
                    if (lastIdrRequest == 0L) null else (now - lastIdrRequest) / 1000.0
                if (!EncoderPresentPath.shouldRequestEnableAfterParameterChange(
                        accessUnitHasIDR = false,
                        udpReceiveAlive = videoAlive,
                        secondsSinceLastEnable = since,
                    )
                ) {
                    return@launch
                }
                sendRecoverEnable(force = false, reason = "encoder format change")
            }
        }
    }
    private val wifiCache = CameraWifiCredentialStore(appContext)
    private val wifiLock = WifiLowLatencyLock(appContext)
    private val power = appContext.getSystemService(android.os.PowerManager::class.java)
    private var feedSessionId = UUID.randomUUID().toString()
    private var socketGeneration = 0
    /** Open from the first LIVE until the operator disconnects (iOS `incidentSessionActive`). */
    private var incidentSessionActive = false
    private var incidentSource: FeedIncidentSource? = null
    /** Repair deadlines held off Bluetooth recovery this stall episode (core `nextSessionHoldCycles`). */
    private var sessionHoldCycles = 0
    private var lastSessionHoldAt: Long? = null

    private val _phase = MutableStateFlow(ConnectionPhase.IDLE)
    val phase: ConnectionPhase get() = _phase.value
    override val phaseFlow: StateFlow<ConnectionPhase> = _phase.asStateFlow()

    private val _failure = MutableStateFlow<String?>(null)
    val failure: StateFlow<String?> = _failure.asStateFlow()
    /** [failure] typed: reason, phase, the same copy (SHELL-02). */
    private val _failureDetail = MutableStateFlow<com.opencapture.opencine.core.ConnectionFailure?>(null)
    override val failureDetail: StateFlow<com.opencapture.opencine.core.ConnectionFailure?> = _failureDetail.asStateFlow()

    override val found: StateFlow<List<FoundCamera>> = ble.found
    val radioOn: StateFlow<Boolean> get() = ble.radioOn
    private val _status = MutableStateFlow(CameraStatus())

    // Most DUML frames are not status frames and leave _status untouched, so its
    // JSON for the Swift bridge is reused until the value changes.
    private var statusJson: Pair<CameraStatus, String>? = null
    /** Camera truth. Control code reads this; Compose collects [chromeStatus]. */
    val status: StateFlow<CameraStatus> = _status.asStateFlow()
    private val _chromeStatus = MutableStateFlow(CameraStatus())
    /** [status] at the 5 Hz HUD budget ([LiveChromeThrottle]); operator fields bypass. */
    val chromeStatus: StateFlow<CameraStatus> = _chromeStatus.asStateFlow()
    /** The last DUML telemetry write. Only it may wait for the HUD interval. */
    private var telemetryStatus: CameraStatus? = null

    /**
     * The camera body shows its own gallery during an established live session.
     * Like DJI Mimo, Live opens Media while this is true and closes it (returning
     * the camera to live) when it turns false (#273, matches iOS).
     */
    private val _cameraGalleryOpen = MutableStateFlow(false)
    val cameraGalleryOpen: StateFlow<Boolean> = _cameraGalleryOpen.asStateFlow()
    private var cameraGalleryAwayTicks = 0

    /** World level from the attitude quaternion; LEVEL polls it at 10 Hz. */
    val levelReading = LevelReading()
    private val _controlNote = MutableStateFlow<String?>(null)
    val controlNote: StateFlow<String?> = _controlNote.asStateFlow()

    fun clearControlNoteIf(note: String) {
        if (_controlNote.value == note) _controlNote.value = null
    }
    private val _controlBusy = MutableStateFlow(false)
    val controlBusy: StateFlow<Boolean> = _controlBusy.asStateFlow()
    private val _focusPoint = MutableStateFlow(0.5f to 0.5f)
    val focusPoint: StateFlow<Pair<Float, Float>> = _focusPoint.asStateFlow()
    private val _gimbalPoseViewFlip = MutableStateFlow(false)
    val gimbalPoseViewFlip: StateFlow<Boolean> = _gimbalPoseViewFlip.asStateFlow()
    private val _gimbalPoseInvertPan = MutableStateFlow(false)
    val gimbalPoseInvertPan: StateFlow<Boolean> = _gimbalPoseInvertPan.asStateFlow()
    private val gimbalLimitWatch = GimbalLimitWatch()
    private var lastGimbalCommand = 0f to 0f
    private val _gimbalLimitPulse = MutableStateFlow(0)
    val gimbalLimitPulse: StateFlow<Int> = _gimbalLimitPulse.asStateFlow()
    @Volatile var lastGimbalLimitContact = GimbalLimitContact()
        private set
    @Volatile var lastGimbalLimitPanSign = 0.0
        private set
    @Volatile var lastGimbalLimitTiltSign = 0.0
        private set
    val browsingMedia: Boolean
        get() = isBrowsingMedia
    private var audioDspBlob: ByteArray? = null
    private var audioTail: Job? = null
    private var audioGeneration = 0L
    private var audioPin: AudioPin? = null
    @Volatile private var pendingGimbalAxes: Pair<Int, Int> =
        CameraCommands.GIMBAL_STICK_CENTER to CameraCommands.GIMBAL_STICK_CENTER
    @Volatile private var gimbalStickHeld = false
    private val gimbalRampFilter = GimbalRampFilter()
    private var moveCountdownJob: Job? = null
    private val _gimbalMoveCountdown = MutableStateFlow<Int?>(null)
    val gimbalMoveCountdown: StateFlow<Int?> = _gimbalMoveCountdown.asStateFlow()
    private var moveToken: Long? = null
    private var moveDatalink: DatalinkDriver? = null
    private var lastMoveReadout: GimbalMoveEngine.Readout? = null
    private val gimbalOverlayMotion = GimbalOverlayMotion()
    @Volatile private var lastValidGimbalAttitudeAt = 0L
    @Volatile private var lastNativeGimbalPose: GimbalWaypoint? = null
    private var captureStableSince = 0L
    private var captureStablePose: GimbalWaypoint? = null
    private var gimbalRestedAt = 0L
    @Volatile private var moveDriving = false
    private var lastMoveHudAt = 0L
    private var lastMoveLogAt = 0L
    private val _gimbalMoveReadout = MutableStateFlow("")
    val gimbalMoveReadout: StateFlow<String> = _gimbalMoveReadout.asStateFlow()
    private var gimbalParamPoll = GimbalParamPoll()
    private var wasRecording = false
    var gimbalRamp: GimbalRamp = GimbalRamp.OFF
    var gimbalDoubleTap: GimbalDoubleTap = GimbalDoubleTap.RECENTER
    /** In-flight Double-tap Level move, judged on each attitude push. */
    @Volatile private var worldLevelSnap: WorldLevelSnap? = null
    private val _gimbalMode = MutableStateFlow(GimbalMode.FOLLOW)
    val gimbalMode: StateFlow<GimbalMode> = _gimbalMode.asStateFlow()
    private val _gimbalSpeed = MutableStateFlow(GimbalSpeed.DEFAULT)
    val gimbalSpeed: StateFlow<GimbalSpeed> = _gimbalSpeed.asStateFlow()
    private val _gimbalProgram = MutableStateFlow(GimbalProgram())
    val gimbalProgram: StateFlow<GimbalProgram> = _gimbalProgram.asStateFlow()
    private val _gimbalMovePaused = MutableStateFlow(false)
    val gimbalMovePaused: StateFlow<Boolean> = _gimbalMovePaused.asStateFlow()
    private val _gimbalMoveRunning = MutableStateFlow(false)
    val gimbalMoveRunning: StateFlow<Boolean> = _gimbalMoveRunning.asStateFlow()
    val hasGimbal: Boolean
        get() = connectedCamera?.model?.hasGimbal == true
    /** Nano is a fixed 1× prime: no zoom chrome and no zoom SET from any input. */
    val supportsZoom: Boolean
        get() = connectedCamera?.model?.supportsZoom == true
    val canRunProgrammedMove: Boolean
        get() = firstPictureSettled && decoder.lastPresentedAt != null && !isLiveVideoStale() &&
            _gimbalProgram.value.canRun && programmedZoomUnavailableReason() == null

    fun programmedZoomUnavailableReason(status: CameraStatus = _status.value): String? {
        val link = datalink
        return if (link != null) link.programmedZoomFailure(_gimbalProgram.value) else
            nativeProgramZoomFailure(_gimbalProgram.value, connectedCamera?.model ?: CameraModel.default, status)
    }

    fun gimbalDebugText(): String = GimbalMoveEngine.formatDebug(_gimbalProgram.value, liveGimbalWaypoint, lastMoveReadout)
    fun predictedGimbalWaypoint(nowSeconds: Double): GimbalWaypoint? = gimbalOverlayMotion.pose(nowSeconds)

    val liveGimbalWaypoint: GimbalWaypoint?
        get() = lastNativeGimbalPose?.copy(zoom = _zoomReadout.value)
    private val commandTimeoutsAt = mutableListOf<Long>()

    var connectedCamera: FoundCamera? = null
        private set
    val nativeISOCapabilities: com.opencapture.opencine.vocabulary.CaptureNativeISOCapabilities
        get() = connectedCamera?.model?.captureProfile?.nativeISO
            ?: com.opencapture.opencine.vocabulary.CaptureNativeISOCapabilities()
    override var joinedSSID: String? = null
        private set

    /** Setup for the next connect (#406); session recovery reuses it. Disconnect resets it. */
    var connectionSetup: CameraConnectionSetup = CameraConnectionSetup.CAMERA_WIFI
        private set
    /** Network and password a Wi-Fi or Hotspot setup moves the camera onto. */
    private var stationNetwork: MultiviewNetworkStore.Network? = null
    /** A camera Wi-Fi connect after a setup that moved the camera sends `07/48 00` first. */
    private var restoreAccessPoint = false
    /** Wi-Fi or Hotspot address that answered with this body's BLE identity. */
    var stationHost: String? = null
        private set
    private var stationSeq = 1200
    /** Station provisioning step; the camera card shows it over the phase label. */
    private val _setupProgress = MutableStateFlow<String?>(null)
    override val setupProgress: StateFlow<String?> = _setupProgress.asStateFlow()
    private val cameraPath: CameraNetworkPath
        get() = if (connectionSetup.movesCamera) station else joinerPath

    /** iOS `CameraSession.supportsFocusMode`. Unknown camera defaults on. */
    val supportsFocusMode: Boolean
        get() {
            val model = connectedCamera?.model ?: return true
            if (!model.supportsFocusMode) return false
            if (model.family.equals("nano", ignoreCase = true)) return false
            val n = model.name.lowercase().replace(" ", "")
            return n.isEmpty() || (!n.contains("nano") && !n.contains("atto"))
        }

    var videoPackets = 0
    var accessUnits = 0
    var framesEnqueued = 0
    var droppedIncomplete = 0
    var decoderErrors = 0
    var hasVideoFormat = false
    var nalTypes = ""
    var lastKeyframeAge = "—"

    var holdsMonitor = false
        private set
    private val _recoveryState = MutableStateFlow<SessionRecoveryUi>(SessionRecoveryUi.Idle)
    val recoveryState: StateFlow<SessionRecoveryUi> = _recoveryState.asStateFlow()

    private var rawAccessUnits = 0
    private var lastIdrRequest = 0L
    private var liveViewEnableSends = 0
    private var firstPictureFormatPoked = false
    private var firstPictureFormatPokeJob: Job? = null
    private val liveEnableGate = SerialSessionGate()
    private var idrHoldEnableCount = 0
    private var firstPictureSettled = false
    private var focusTrackPending = false
    private var lastFocusTrackAt: Long? = null
    private var streamStartedAt: Long? = null
    private var lastBleNotifyAt: Long? = null
    @Volatile private var isBrowsingMedia = false
    @Volatile private var mediaPictureGeneration = 0L
    private var mediaReturnPending = false
    @Volatile private var operatorOverlayHeld = false
    private var evBeforeFacePriority: EvComp? = null
    private var lastFacePriorityEVAt = 0L
    private var facePriorityAcquireAt: Long? = null
    private var needsForegroundRecover = false
    private var nextTrackingId = 1
    private var mediaListCounter = 1
    private val feedWatchdog = LiveViewEnablePolicy.State()
    private var coreWatchdog = 0L
    /** Gating inputs of the last watchdog pass, for incidents (PI-2E slow -12903 recovery). */
    private var watchdogGate: FeedIncidentWatchdogGate? = null
    private var recoveryCameraId: String? = null
    private var recoveryDeviceName = ""
    private var datalink: DatalinkDriver? = null
        set(value) {
            val replaced = field !== value
            field = value
            if (replaced) {
                controlSeam?.linkDidChange()
                cachedMediaService?.attachIngress(value?.mediaIngress ?: DjiAndroidMediaIngressSlot())
            }
        }

    /** OpenCineCore seam for ISO, white balance and record (CORE-02). UI controls submit here. */
    override val control: DjiCameraSessionAdapter
        get() = controlBinding.session
    private val controlBinding by lazy {
        DjiControlSessionBinding(this, scope, onClose = { disconnect() })
    }
    private val controlSeam: DjiCameraSessionAdapter? get() = controlBinding.cached

    private var cachedMediaService: DjiAndroidMediaService? = null
    private var mediaReturnOwner: Long? = null
    private val mediaReturnSession = com.opencapture.opencine.media.MonitorMediaReturnSession(scope)
    private val actualMediaPort = object : DjiAndroidMediaPort {
        override val mediaFacts: DjiAndroidMediaFacts?
            get() {
                val cameraID = connectedCamera?.id ?: recoveryCameraId ?: return null
                val snapshot = control.current
                val identity = DjiAndroidMediaIdentity(snapshot.session, snapshot.epoch, cameraID)
                val link = datalink
                return DjiAndroidMediaFacts(identity,
                    _phase.value == ConnectionPhase.LIVE && controlLeaseAllows() && link != null && !link.isClosed && !link.isRebuilding,
                    _cameraGalleryOpen.value, _status.value.inPlayback,
                    DJIMediaSourcePolicy.observed(connectedCamera?.model, _status.value.inPlayback, _status.value.internalTotalMb))
            }
        private fun current(source: DjiAndroidMediaIdentity, returning: Boolean = false): Boolean {
            val facts = mediaFacts ?: return false
            return if (returning) facts.identity.sameConnection(source)
                else facts.canQuery && facts.identity == source
        }
        override fun mediaBrowseChanged(active: Boolean, source: DjiAndroidMediaIdentity) {
            if (!current(source, returning = !active)) return
            val owner = markBrowsingMedia(active, resumePending = !active)
            mediaReturnOwner = if (active) null else owner
        }
        override fun setMediaWireHeld(held: Boolean, source: DjiAndroidMediaIdentity) {
            if (current(source, returning = !held)) setMediaTransportBrowsing(held)
        }
        override fun writeMedia(set: Int, command: Int, payload: ByteArray, source: DjiAndroidMediaIdentity) {
            if (!current(source)) throw MediaServiceException(MediaServiceFailure.RETIRED)
            datalink?.sendDuml(set, command, payload) ?: throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
        }
        override fun enterMediaPlayback(source: DjiAndroidMediaIdentity) {
            if (!current(source)) throw MediaServiceException(MediaServiceFailure.RETIRED)
            val link = datalink ?: throw MediaServiceException(MediaServiceFailure.UNAVAILABLE)
            if (DjiNative.isAvailable) link.sendCommand(DjiNative.CMD_ENTER_PLAYBACK)
            else link.sendDuml(MediaCommands.SET_CAMERA, MediaCommands.CMD_PLAYBACK, MediaCommands.enterPlaybackPayload())
        }
        override fun claimMediaReturn(source: DjiAndroidMediaIdentity, operation: suspend (DjiAndroidMediaReturnAuthority) -> Unit): kotlinx.coroutines.Deferred<Unit>? {
            val owner = mediaReturnOwner ?: return null
            if (!current(source, returning = true) || !ownsMediaReturnContext(owner)) return null
            // The shared scheduler belongs to the native session, independent of gallery collectors.
            mediaReturnSession.start(
                ifCurrent = { current(source, returning = true) && ownsMediaReturnContext(owner) },
                operation = {
                withMediaLiveResumeOwner(owner) {
                    val startedAt = SystemClock.elapsedRealtime()
                    fun admitted(): Boolean = current(source, returning = true) && ownsMediaLiveResume(owner)
                    val authority = DjiAndroidMediaReturnAuthority(
                        isCurrent = ::admitted,
                        inPlayback = { _status.value.inPlayback },
                        pictureFresh = { hasRecoveryPicture(startedAt) },
                        writeExit = {
                            if (admitted()) datalink?.sendDuml(MediaCommands.SET_CAMERA, MediaCommands.CMD_PLAYBACK, MediaCommands.exitPlaybackPayload())
                        },
                        enableLiveView = { admitted() && restartLiveViewAfterMedia() },
                        completed = { result ->
                            if (admitted() && result == MediaLiveResumeRunner.Result.EXHAUSTED) mediaLiveResumeExhausted(owner)
                        })
                    operation(authority)
                }
            })
            return mediaReturnSession.task
        }
    }
    /** Real connection identity remains available during a same-session driver-repair gap. */
    val mediaConnectionIdentity: DjiAndroidMediaIdentity? get() = actualMediaPort.mediaFacts?.identity

    /** Presentation authority is independent of camera readiness and driver presence. */
    fun claimMediaGalleryCover(): DjiAndroidMediaGalleryCover {
        val source = actualMediaPort.mediaFacts?.identity
        val nativeSession = control.id
        cachedMediaService?.retire()
        mediaReturnOwner = null
        if (actualMediaPort.mediaFacts?.canQuery != true) setMediaTransportBrowsing(false)
        return DjiAndroidMediaGalleryCover.claim(
            mark = { markBrowsingMedia(true) },
            owns = { owner ->
                val currentSource = actualMediaPort.mediaFacts?.identity
                val sameConnection = if (source == null) currentSource == null else currentSource?.sameConnection(source) == true
                control.id == nativeSession && sameConnection && owner == mediaPictureGeneration && isBrowsingMedia
            },
            release = {
                val canReturn = source != null && actualMediaPort.mediaFacts?.identity?.sameConnection(source) == true &&
                    _phase.value == ConnectionPhase.LIVE
                val owner = markBrowsingMedia(false, resumePending = canReturn)
                if (canReturn && source != null) {
                    mediaReturnOwner = owner
                    (services.get<CameraMediaService>() as DjiAndroidMediaService).returnFromGalleryCover(source)
                } else setMediaTransportBrowsing(false)
            })
    }
    override val services: CameraServices
        get() {
            val service = cachedMediaService ?: DjiAndroidMediaService(control.id, actualMediaPort,
                DjiAndroidMediaTiming(SystemClock::elapsedRealtime) { kotlinx.coroutines.delay(it) },
                datalink?.mediaIngress ?: DjiAndroidMediaIngressSlot()).also { cachedMediaService = it }
            return CameraServices().plus(CameraMediaService::class, service)
        }

    private var reportedCapture = CameraStatus()

    // Camera-reported values for the seam. [status] carries optimistic HUD values; these never do.
    private var reportedIsoIndex: Int? = null
    private var reportedWhiteBalance: ReportedWhiteBalance? = null
    private var reportedRecording: Boolean? = null
    private var connectJob: Job? = null
    private var keepaliveJob: Job? = null
    private var frameJob: Job? = null
    private val waiters = ConcurrentHashMap<Int, FrameWaiter>()
    private val pairingHold = ConcurrentHashMap<Int, DumlFrame>()
    private val inflight = ConcurrentHashMap<Int, InflightSend>()
    private val inflightPending = ConcurrentHashMap<Int, InflightSend>()
    private var reconnectJob: Job? = null
    private var reconnectTarget: String? = null
    /** This session's hold on the reporting camera path, from connect start until disconnect. */
    private var reportingCameraPath: AutoCloseable? = null
    private val _connectionTargetId = MutableStateFlow<String?>(null)
    val connectionTargetId: StateFlow<String?> = _connectionTargetId.asStateFlow()
    private var feedRecoveryJob: Job? = null
    private val endpointCommandAdmission = EndpointCommandAdmission()
    private var lastFirstPictureLogAt = 0L
    private var lastFirstPictureSignature = ""
    private var lastRecoverSkipAt = 0L
    private var lastRecoverSkipReason = ""
    private var formatPin: FormatPin? = null
    private var shootingModeRevision: Int = 0
    /** iOS `CameraSession.isFormatPinActive`; FORMAT sheet skips reseat. */
    val isFormatPinActive: Boolean
        get() = formatPin != null
    private var colorPin: ColorPin? = null
    private var expoPin: ExpoPin? = null
    private var gimbalModePin: CameraValuePin<GimbalMode>? = null
    private var gimbalSpeedPin: CameraValuePin<GimbalSpeed>? = null
    /** Operator speed/tilt lock held while Motion Control runs on Fast. */
    private val gimbalPrep = GimbalPrepRestore()
    private var gimbalFollowFamilyConfirmed = false
    private var shootingModePin: ShootingModePin? = null
    private var whiteBalancePin: WhiteBalancePin? = null
    private var focusPin: FocusPin? = null
    private var isoLimitPin: IsoLimitPin? = null
    private var aperturePin: CameraValuePin<Int>? = null
    private var gimbalStickMapping = GimbalStickMapping()
    /** Last pid `0x38` GET reply. BLE fallback fires when this goes stale. */
    @Volatile private var lastSelfieFlipReplyElapsed = 0L
    @Volatile private var lastAssistMirror = false
    private var teleColorSent = false
    private var restoreDLog2OnWide = false
    @Volatile var zoomColorHopPending = false
        private set
    private var zoomColorHopUntilElapsed = 0L
    private var zoomColorHopGeneration = 0L
    private var pendingZoomAfterHop: Double? = null
    private var pendingZoomAfterHopStage: ((ControlWireEvent) -> Unit)? = null
    private var zoomStop = 1.0
    private var zoomStopTouched = false
    var zoomPinchPreview: Double? = null
        private set
    /**
     * Chip-tap target until `cam_fov` catches up, on the same settle window as every other
     * control. It has to expire on its own: the body answers an ask it cannot honour by clamping
     * to its own ceiling, and it moves the lens without being asked (a FORMAT change resets to 1×,
     * so does the operator working the camera directly). None of those ever report the asked-for
     * factor, so a pin that only cleared on a match would sit on the chip showing a zoom the
     * camera is not at for the rest of the session.
     */
    private var zoomPin: CameraValuePin<Double>? = null
    val zoomOptimistic: Double?
        get() = zoomPin?.expected
    private var zoomPinchAnchor = 1.0
    private var lastPinchLens: Int? = null
    private var lastPinchLogTenths: Double? = null
    private var lastZoomWireAt = 0L
    private val lastZoomActivityAt: Long?
        get() = maxOf(lastZoomWireAt, datalink?.lastProgrammedZoomAt ?: 0L).takeIf { it > 0L }
    private var pendingZoomPayload: ByteArray? = null
    private var pendingZoomStage: ((ControlWireEvent) -> Unit)? = null
    private var zoomFlushJob: Job? = null
    private val faceDetector = appHost.createFaceDetector()
    private val _faceAFArmed = MutableStateFlow(false)
    val faceAFArmed: StateFlow<Boolean> = _faceAFArmed.asStateFlow()
    private val _wantsFaceDetect = MutableStateFlow(false)
    val wantsFaceDetect: StateFlow<Boolean> = _wantsFaceDetect.asStateFlow()
    private var faceAFArmJob: Job? = null
    private var faceTickJob: Job? = null
    private var lastFaceHitAt: Long? = null
    private var lastFaceAt: Long? = null
    private val _zoomReadout = MutableStateFlow(1.0)
    val zoomReadout: StateFlow<Double> = _zoomReadout.asStateFlow()
    private val _zoomDialReadout = MutableStateFlow(1.0)
    val zoomDialReadout: StateFlow<Double> = _zoomDialReadout.asStateFlow()
    private val _zoomPinching = MutableStateFlow(false)
    val zoomPinching: StateFlow<Boolean> = _zoomPinching.asStateFlow()
    private var searchBox: TrackingBox? = null
    private var subjectBox: TrackingBox? = null
    private var isTracking = false
    private var trackingSawLock = false
    private var faceBox: TrackingBox? = null
    private var sceneFaces: List<TrackingBox> = emptyList()
    private var lastTapFocusAt: Long? = null
    /** The operator's latest ActiveTrack box, until the camera reports it. */
    private var trackingRequest: TrackingBox? = null
    private var trackingRequestAt: Long? = null
    private var lastOperatorClearAt: Long? = null
    private var lastSubjectPushAt: Long? = null
    private var lastLiveTrackingAt: Long? = null
    private var lastGimbalStickAt: Long? = null
    private var lastGimbalThrowAt: Long? = null
    /** Last tracked SET on the datalink. Core `FeedWatchdog.cameraSetGrace` holds after it. */
    private var lastCameraSetAt: Long? = null
    private var trackingPollJob: Job? = null
    private val _trackingHud = MutableStateFlow(TrackingHud())
    val trackingHud: StateFlow<TrackingHud> = _trackingHud.asStateFlow()
    /** Feed long-press AE lock. Status that no longer `holds` it clears it (core policy). */
    private val _aeLock = MutableStateFlow<AutoExposureLock?>(null)
    val aeLock: StateFlow<AutoExposureLock?> = _aeLock.asStateFlow()
    private var aeLockChecked: Pair<Int, Int>? = null
    /** WB Mode AWB Lock: the locked Custom Kelvin. Cleared like [aeLock] (core `AutoWhiteBalanceLock`). */
    private val _awbLockKelvin = MutableStateFlow<Int?>(null)
    val awbLockKelvin: StateFlow<Int?> = _awbLockKelvin.asStateFlow()
    private var awbLockChecked: Pair<Int, Int>? = null
    private val _isReconnecting = MutableStateFlow(false)
    val isReconnecting: StateFlow<Boolean> = _isReconnecting.asStateFlow()

    init {
        scope.launch {
            var publishedAt = 0L
            _status.collectLatest { next ->
                val shown = _chromeStatus.value
                if (next == shown) return@collectLatest
                delay(LiveChromeThrottle.holdMs(shown, next, next === telemetryStatus, publishedAt,
                    SystemClock.elapsedRealtime()))
                _chromeStatus.value = next
                publishedAt = SystemClock.elapsedRealtime()
            }
        }
        ble.onLinkLost = {
            if (_phase.value == ConnectionPhase.LIVE || holdsMonitor) {
                beginSessionRecovery("BLE dropped", SessionRecoveryTrigger.BLE_DROPPED)
            } else {
                failLink("the camera disconnected")
            }
        }
        joiner.onPathLost = {
            if (_phase.value == ConnectionPhase.LIVE || holdsMonitor) {
                beginSessionRecovery(
                    "the camera Wi-Fi disconnected",
                    SessionRecoveryTrigger.SOFTAP_LOST,
                )
            } else {
                failLink("the camera Wi-Fi disconnected")
            }
        }
        joiner.onReassociated = {
            Log.i(TAG, "wifi: SoftAP reassociated — rebuild UDP, keep LIVE")
            endGimbalStick()
            startFeedRecovery {
                rebuildDatalinkKeepingPicture("wifi reassociated")
            }
        }
    }

    override fun startScan() {
        startScan(reconnect = null)
    }

    override fun stopScan() = ble.stopScan()

    fun startScan(reconnect: String?) {
        if (reconnect != null && !holdsMonitor) {
            cachedMediaService?.retire()
            cachedMediaService = null
            mediaReturnOwner = null
            controlBinding.beginConnection()
            reportedCapture = CameraStatus()
        }
        reconnectTarget = reconnect
        _connectionTargetId.value = reconnect
        _isReconnecting.value = reconnect != null
        _phase.value = ConnectionPhase.SCANNING
        _failure.value = null
        _failureDetail.value = null
        ble.startScan()
        if (reconnectJob == null) {
            reconnectJob =
                scope.launch {
                    ble.found.collect { cameras ->
                        val target = reconnectTarget ?: return@collect
                        val match = cameras.firstOrNull { it.id == target } ?: return@collect
                        reconnectTarget = null
                        connect(match)
                    }
                }
        }
    }

    override fun reconnect(id: String) {
        if (_phase.value == ConnectionPhase.LIVE && connectedCamera?.id == id &&
            !_recoveryState.value.isRecovering && !holdsMonitor
        ) {
            return
        }
        if (!holdsMonitor && !phaseAllowsReconnect(_phase.value)) return
        if (_phase.value == ConnectionPhase.LIVE && !holdsMonitor) leaveLiveForReconnect()
        found.value.firstOrNull { it.id == id }?.let {
            connect(it)
            return
        }
        startScan(reconnect = id)
    }

    fun connect(camera: FoundCamera) {
        if (_phase.value == ConnectionPhase.LIVE && connectedCamera?.id == camera.id &&
            !_recoveryState.value.isRecovering && !holdsMonitor
        ) {
            return
        }
        if (!holdsMonitor) {
            when (_phase.value) {
                ConnectionPhase.IDLE, ConnectionPhase.SCANNING, ConnectionPhase.FAILED -> Unit
                ConnectionPhase.LIVE -> leaveLiveForReconnect()
                else -> return
            }
        }
        if (!holdsMonitor) {
            cachedMediaService?.retire()
            cachedMediaService = null
            mediaReturnOwner = null
            controlBinding.beginConnection()
            reportedCapture = CameraStatus()
        }
        reconnectTarget = null
        _connectionTargetId.value = camera.id
        _isReconnecting.value = false
        if (reportingCameraPath == null) reportingCameraPath = appHost.beginCameraPath()
        LocalVPNProbe.noteIfActive(appContext) { DjiLog.log("notice", "session", "vpn", it) }
        connectJob?.cancel()
        if (!holdsMonitor) publishPhase(ConnectionPhase.CONNECTING_GATT)
        connectJob =
            scope.launch {
                try {
                    run(camera)
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Exception) {
                    if (_phase.value == ConnectionPhase.IDLE) return@launch
                    if (holdsMonitor) {
                        Log.i(TAG, "session: recovery attempt failed ${e.message}")
                        return@launch
                    }
                    if (_phase.value == ConnectionPhase.FAILED) return@launch
                    val why = e.message ?: e.toString()
                    DjiLog.log(
                        "error",
                        "session",
                        "connect",
                        "session: connect failed at ${_phase.value.name.lowercase()} — $why",
                    )
                    _failure.value = why
                    _failureDetail.value = DjiFailures.classify(
                        e, _phase.value, why,
                        hotspotOff = connectionSetup == CameraConnectionSetup.PHONE_HOTSPOT && station.address(true) == null,
                    )
                    _phase.value = ConnectionPhase.FAILED
                }
            }
    }

    fun attachSurface(surface: Surface?) {
        if (isMultiviewControlOnly) return
        if (isMultiviewBorrowed) {
            // The returning tile may already own the decoder; only drop our own output.
            if (surface == null) borrowedSurface?.let(decoder::detachSurface) else decoder.attachSurface(surface)
            borrowedSurface = surface
            return
        }
        decoder.attachSurface(surface)
    }

    /**
     * SIMULATED, debug review only (a `ReviewLaunch` LIVE): presents [status] from [camera] as a live
     * session through the same reported-capture projection a camera report takes. Opens no radio,
     * link or decoder; with no link, every command is refused. Never call it in a camera session.
     */
    fun stageSimulatedLive(camera: FoundCamera, status: CameraStatus) {
        check(datalink == null && !isMultiviewBorrowed) { "A simulated review never replaces a camera session" }
        connectedCamera = camera
        reportedCapture = status
        noteReportedExposure(status)
        _status.value = status
        _chromeStatus.value = status
        controlSeam?.sessionDidChange()
        _phase.value = ConnectionPhase.LIVE
    }

    /** Borrow the tile's transport and decoder; Multiview remains the sole repair owner. */
    fun updateMultiview(camera: FoundCamera?, driver: DatalinkDriver?, status: CameraStatus) {
        if (!isMultiviewBorrowed) return
        if (connectedCamera?.id != camera?.id) {
            cachedMediaService?.retire()
            cachedMediaService = null
            mediaReturnOwner = null
            controlBinding.beginConnection()
            reportedCapture = CameraStatus()
        }
        connectedCamera = camera
        datalink = driver
        // Tile settings are decoded reports; editor pins live only in this borrowed session.
        reportedCapture = status
        _status.value = status
        controlSeam?.sessionDidChange()
        hasVideoFormat = decoder.hasFormat
        _phase.value = ConnectionPhase.LIVE
    }

    val multiviewPose: GimbalStickMapping
        get() = gimbalStickMapping

    fun adoptMultiviewPose(pose: GimbalStickMapping) {
        if (!isMultiviewBorrowed || isMultiviewControlOnly) return
        gimbalStickMapping = pose
        syncGimbalPose()
    }

    fun receiveMultiview(frame: DumlFrame) {
        if (!isMultiviewBorrowed || !controlLeaseAllows()) return
        ingestDatalinkFrame(frame)
    }

    fun releaseMultiview() {
        formatPin = null
        if (!isMultiviewBorrowed) return
        cachedMediaService?.retire()
        cachedMediaService = null
        mediaReturnOwner = null
        controlBinding.retire(com.opencapture.opencine.core.SessionCloseReason.REQUESTED)
        reportedCapture = CameraStatus()
        controlLease?.invalidate()
        if (!isMultiviewControlOnly) {
            endGimbalStick()
            cancelProgrammedMove()
            cancelTracking()
            faceAFArmJob?.cancel()
            faceAFArmJob = null
        }
        inflight.clear()
        inflightPending.clear()
        failAllWaiters(kotlinx.coroutines.CancellationException("Multiview took the camera back"))
        datalink = null
        if (isMultiviewControlOnly) {
            connectedCamera = null
            _phase.value = ConnectionPhase.IDLE
            scope.cancel()
        }
    }

    override fun disconnect() {
        cachedMediaService?.retire()
        mediaReturnOwner = null
        if (isMultiviewBorrowed) {
            releaseMultiview()
            return
        }
        cachedMediaService?.retire()
        cachedMediaService = null
        mediaReturnOwner = null
        controlBinding.retire(com.opencapture.opencine.core.SessionCloseReason.REQUESTED)
        reportedCapture = CameraStatus()
        reportingCameraPath?.close()
        reportingCameraPath = null
        // Operator ended the session: an incident still open ends as userEnded.
        val outgoingIncidentSource = incidentSource
        incidentSource = null
        outgoingIncidentSource?.endSession(SystemClock.elapsedRealtime() / 1000.0)
        incidentSessionActive = false
        cancelSessionRecovery(clearHoldsMonitor = true)
        reconnectTarget = null
        _connectionTargetId.value = null
        _isReconnecting.value = false
        feedRecoveryJob?.cancel()
        feedRecoveryJob = null
        connectJob?.cancel()
        keepaliveJob?.cancel()
        frameJob?.cancel()
        resetGimbalControls()
        endGimbalStick()
        // Cancel, do not fail, the suspended control round-trips. A waiter
        // resumed with a runtime exception escapes its fire-and-forget
        // `scope.launch` and crashes the process (#348). CancellationException
        // is treated as cancellation by the coroutine machinery.
        failAllWaiters(kotlinx.coroutines.CancellationException("the camera disconnected"))
        pairingHold.clear()
        inflight.clear()
        inflightPending.clear()
        commandTimeoutsAt.clear()
        disposeDatalink()
        ble.disconnect()
        decoder.reset()
        videoHistory.reset()
        releaseCameraPath()
        wifiLock.release()
        connectedCamera = null
        joinedSSID = null
        connectionSetup = CameraConnectionSetup.CAMERA_WIFI
        stationNetwork = null
        restoreAccessPoint = false
        stationHost = null
        _setupProgress.value = null
        holdsMonitor = false
        isBrowsingMedia = false
        mediaPictureGeneration += 1
        mediaReturnPending = false
        mediaReturnSession.cancel()
        _phase.value = ConnectionPhase.IDLE
        _status.value = CameraStatus()
        reportedIsoIndex = null
        reportedWhiteBalance = null
        reportedRecording = null
        _failure.value = null
        _failureDetail.value = null
        _controlNote.value = null
        _controlBusy.value = false
        formatPin = null
        shootingModeRevision++
        colorPin = null
        expoPin = null
        gimbalModePin = null
        gimbalSpeedPin = null
        gimbalFollowFamilyConfirmed = false
        shootingModePin = null
        whiteBalancePin = null
        _aeLock.value = null
        _awbLockKelvin.value = null
        focusPin = null
        isoLimitPin = null
        aperturePin = null
        gimbalStickMapping = GimbalStickMapping()
        lastSelfieFlipReplyElapsed = 0L
        lastAssistMirror = false
        syncGimbalPose()
        teleColorSent = false
        restoreDLog2OnWide = false
        zoomColorHopPending = false
        zoomColorHopUntilElapsed = 0L
        zoomColorHopGeneration += 1
        discardZoomAfterHop()
        resetZoomHud()
        clearLocalTracking()
        clearFaceAF()
        _faceAFArmed.value = false
        faceAFArmJob?.cancel()
        faceAFArmJob = null
        faceTickJob?.cancel()
        faceTickJob = null
        discardPendingZoom()
        zoomFlushJob?.cancel()
        zoomFlushJob = null
        lastTapFocusAt = null
        _focusPoint.value = 0.5f to 0.5f
        refreshTrackingHud()
        audioTail?.cancel()
        audioTail = null
        audioPin = null
        audioDspBlob = null
        videoPackets = 0
        accessUnits = 0
        framesEnqueued = 0
        droppedIncomplete = 0
        decoderErrors = 0
        hasVideoFormat = false
        nalTypes = ""
        lastKeyframeAge = "—"
        streamStartedAt = null
        liveViewEnableSends = 0
        resetFirstPictureFormatPoke()
        idrHoldEnableCount = 0
        firstPictureSettled = false
        focusTrackPending = false
        lastFocusTrackAt = null
        lastCameraSetAt = null
        lastBleNotifyAt = null
        needsForegroundRecover = false
        feedWatchdog.reset()
        if (coreWatchdog != 0L && DjiNative.isAvailable) DjiNative.feedWatchdogReset(coreWatchdog)
        ble.startScan()
    }

    fun close() {
        disconnect()
        faceDetector.shutdown()
        ble.stopScan()
        ble.close()
    }

    private suspend fun run(camera: FoundCamera) {
        if (!DjiNative.isAvailable) error("Swift core is not loaded — run just android-core")
        // A new transport needs a fresh exposure report, even when reconnecting the same camera.
        _status.value = _status.value.copy(meteredEv = -1)
        connectedCamera = camera
        rawAccessUnits = 0
        lastIdrRequest = 0L
        liveViewEnableSends = 0
        resetFirstPictureFormatPoke()
        idrHoldEnableCount = 0
        firstPictureSettled = false
        focusTrackPending = true
        lastFocusTrackAt = null
        lastCameraSetAt = null
        streamStartedAt = null
        feedSessionId = UUID.randomUUID().toString()
        socketGeneration = 0
        feedWatchdog.reset()
        if (coreWatchdog != 0L && DjiNative.isAvailable) DjiNative.feedWatchdogReset(coreWatchdog)
        if (!holdsMonitor) {
            decoder.reset()
            videoHistory.reset()
        } else decoder.beginIDRHold()
        publishPhase(ConnectionPhase.CONNECTING_GATT)
        startFrameRouter()
        ble.connect(camera)
        val credentialSourceCurrent = ble.captureCredentialConnection()

        pairingHold.clear()
        inflight.clear()
        inflightPending.clear()
        publishPhase(ConnectionPhase.PAIRING)
        ble.send(DjiNative.command(DjiNative.CMD_SESSION_WAKE, 0x802B))
        ble.send(DjiNative.command(DjiNative.CMD_SET_PAIRING_PIN, 0x8092, camera.model.pairingToken))
        publishPhase(ConnectionPhase.AWAITING_APPROVAL)
        try {
            completePairing()
        } catch (_: TimeoutCancellationException) {
            error("pairing timed out. Tap Approve on the camera if it asked.")
        }

        startKeepalive(joinedSSID)
        if (connectionSetup.movesCamera) {
            val ssid = runStation(camera)
            startKeepalive(ssid)
            return
        }
        publishPhase(ConnectionPhase.READING_WIFI_CREDS)
        val restored = restoreAccessPoint
        if (restored) restoreCameraAccessPoint()
        val credsFromCache = withCredentialIO(credentialSourceCurrent, transaction = wifiCache.ioTransaction) { wifiCache.load(camera.id) } != null
        val skipApSettle = !restored && joiner.isProcessBound() && credsFromCache
        if (!skipApSettle) delay(200)
        ble.send(DjiNative.command(DjiNative.CMD_SESSION_5310, 0x8053))
        runCatching { waitFrame(0x53, 0x10, 2_000) }
        if (!skipApSettle) delay(600)
        val (ssid, pass) = wifiCredsAfterPairing(camera, credentialSourceCurrent)
        DjiLog.log(
            "info",
            "session",
            "creds",
            "creds: SSID $ssid (${pass.length} char password, ${if (credsFromCache) "cached" else "from BLE"}) body=${camera.model.name}",
        )

        publishPhase(ConnectionPhase.JOINING_WIFI)
        if (!joiner.isProcessBound()) {
            // Core `CameraSoftAPSwitch.joinDeadlineSeconds`: a 5.8 GHz SoftAP in a DFS region
            // beacons about 60 s after power-on; 45 s gave up first (#235).
            val joined = joiner.join(ssid, pass, timeoutMillis = 90_000, wpa3 = camera.model.wpa3)
            if (!joined) {
                // iOS parity: a Pocket "Reset Wi-Fi" regenerates the passphrase.
                // Drop cached creds so the next tap re-reads them over BLE.
                if (credsFromCache) {
                    DjiLog.log(
                        "info",
                        "session",
                        "creds",
                        "creds: join failed with cached creds — dropping cache",
                    )
                    withCredentialIO(credentialSourceCurrent, transaction = wifiCache.ioTransaction) { wifiCache.remove(camera.id) }
                }
                error(
                    "couldn't join camera Wi-Fi. Tap the system Join prompt if Android asked. " +
                        "On 5.8 GHz the camera Wi-Fi can take about a minute to appear. Try again, or set the camera to 2.4 GHz (Settings, Wireless, Frequency) for a faster join.",
                )
            }
        }
        // Known good only once the join worked.
        withCredentialIO(credentialSourceCurrent, transaction = wifiCache.ioTransaction) { wifiCache.save(camera.id, ssid, pass) }
        joinedSSID = ssid
        wifiLock.acquire()

        publishPhase(ConnectionPhase.OPENING_DATALINK)
        openDatalinkKeepingLive(camera)
        startKeepalive(ssid)
    }

    /** Explicit forget uses this session's cache and caller Job, independently of its GATT attempt. */
    suspend fun forgetWifiCredentials(cameraId: String) {
        withCredentialIO({ true }, transaction = wifiCache.ioTransaction) { wifiCache.remove(cameraId) }
    }

    private suspend fun wifiCredsAfterPairing(
        camera: FoundCamera, credentialSourceCurrent: () -> Boolean,
    ): Pair<String, String> {
        val cached = withCredentialIO(credentialSourceCurrent, transaction = wifiCache.ioTransaction) { wifiCache.load(camera.id) }
        if (cached != null) {
            val resolved =
                CameraWifiResolution.resolve(
                    cameraId = camera.id,
                    savedSSID = null,
                    memoryCameraId = camera.id,
                    memorySsid = cached.first,
                    memoryPassword = cached.second,
                    keychainSsid = cached.first,
                    keychainPassword = cached.second,
                    advertisedName = camera.name,
                )
            if (resolved.skipBle && resolved.ssid != null && resolved.password != null) {
                if (resolved.ssid != cached.first) {
                    DjiLog.log(
                        "info",
                        "session",
                        "creds",
                        "creds: live BLE name ${resolved.ssid} replaces cached SSID ${cached.first}",
                    )
                }
                DjiLog.log(
                    "info",
                    "session",
                    "creds",
                    "creds: skipping BLE GetSSID/GetPassword — ${resolved.source} SSID ${resolved.ssid}",
                )
                return resolved.ssid to resolved.password
            }
        }
        val ssid =
            readWifiString("GetSSID", 0x07, 0x07) {
                ble.send(DjiNative.command(DjiNative.CMD_GET_WIFI_SSID, 0x8007))
            }
        val pass =
            readWifiString("GetPassword", 0x07, 0x0E) {
                ble.send(DjiNative.command(DjiNative.CMD_GET_WIFI_PASSWORD, 0x800E))
            }
        return ssid to pass
    }

    /**
     * iOS `openDatalinkKeepingLive`: handshake then `0x09/0xa8` in the same
     * turn. SoftAP still up after a miss → retry, do not pop pairing.
     */
    private suspend fun openDatalinkKeepingLive(
        camera: FoundCamera, warmRejoin: Boolean = false, pictureOwner: Long? = null,
    ) {
        val commandOwner = endpointCommandAdmission.begin()
        try {
            negotiateDatalinkKeepingLive(camera, warmRejoin, pictureOwner)
        } finally {
            endpointCommandAdmission.finish(commandOwner)
        }
    }

    private suspend fun negotiateDatalinkKeepingLive(
        camera: FoundCamera, warmRejoin: Boolean, pictureOwner: Long?,
    ) {
        val existing = datalink
        val dl =
            existing?.takeIf { LiveViewEnablePolicy.shouldReuseDatalink(it.isClosed) }
                ?: makeDatalink(camera, stationHost.takeIf { connectionSetup.movesCamera })
        var attempt = 0
        while (true) {
            try {
                withTimeout(LiveViewEnablePolicy.handshakeOpenTimeoutMs()) {
                    interruptibleDatalinkOpen {
                        dl.open(
                            afterHandshake = {
                                if (!LiveViewEnablePolicy.shouldCommitLiveHandshake(
                                        driverOwned = datalink === dl,
                                        isClosed = dl.isClosed,
                                        isCancelled = Thread.currentThread().isInterrupted,
                                    )
                                ) {
                                    Log.i(TAG, "live: ignore stale datalink open")
                                    return@open
                                }
                                publishPhase(ConnectionPhase.LIVE)
                                beginFeedIncidentSession()
                                if (pictureOwner == null || ownsLivePicture(pictureOwner)) {
                                    sendCapturedLiveView("first picture")
                                }
                            },
                        )
                    }
                }
                return
            } catch (e: TimeoutCancellationException) {
                kotlinx.coroutines.currentCoroutineContext().ensureActive()
                Log.i(TAG, "session: handshake open timed out")
                val miss =
                    DatalinkHandshakeException("camera never answered the datalink handshake")
                if (LiveViewEnablePolicy.shouldKickAfterHandshakeTimeout(cameraPath.isProcessBound())) {
                    throw miss
                }
                attempt += 1
                if (warmRejoin || LiveViewEnablePolicy.shouldGiveUpOpenRetry(attempt)) {
                    Log.i(TAG, "session: handshake give-up after $attempt opens")
                    throw miss
                }
                Log.i(TAG, "session: handshake miss #$attempt — SoftAP up, retry (no kick)")
                delay(LiveViewEnablePolicy.HANDSHAKE_RETRY_PAUSE_MS)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                if (LiveViewEnablePolicy.shouldKickAfterHandshakeTimeout(cameraPath.isProcessBound())) {
                    throw e
                }
                attempt += 1
                if (warmRejoin || LiveViewEnablePolicy.shouldGiveUpOpenRetry(attempt)) {
                    Log.i(TAG, "session: handshake give-up after $attempt opens")
                    throw e
                }
                Log.i(TAG, "session: handshake miss #$attempt — SoftAP up, retry (no kick)")
                delay(LiveViewEnablePolicy.HANDSHAKE_RETRY_PAUSE_MS)
            }
        }
    }

    // ---- Wi-Fi and Hotspot setups (#406) --------------------------------------------------------

    /**
     * Setup for the next [connect] or [reconnect]. [network] carries the Wi-Fi or Hotspot
     * credentials; [restoreAccessPoint] asks a camera Wi-Fi connect to bring back the access
     * point of a camera a setup left in station role. A live session on another setup must
     * be disconnected first.
     */
    override fun useSetup(
        setup: CameraConnectionSetup,
        network: MultiviewNetworkStore.Network?,
        restoreAccessPoint: Boolean,
    ) {
        if (setup != connectionSetup) stationHost = null
        connectionSetup = setup
        stationNetwork = network.takeIf { setup.movesCamera }
        this.restoreAccessPoint = restoreAccessPoint && !setup.movesCamera
        station.hotspot = setup == CameraConnectionSetup.PHONE_HOTSPOT
    }

    private fun releaseCameraPath() {
        joiner.release()
        station.release()
    }

    private fun cameraNetworkUsable(): Boolean =
        if (connectionSetup.movesCamera) station.address() != null else joiner.hasUsableCameraNetwork()

    private fun stationLog(line: String) = DjiLog.log("info", "session", "station", "station: $line")

    /** BLE request on the session link; the reply is matched by opcode like every other wait. */
    private suspend fun exchangeBle(kind: Int, extra: String? = null, timeoutMs: Long = 12_000): ByteArray {
        stationSeq = (stationSeq + 1) and 0xFFFF
        val bytes = DjiNative.command(kind, stationSeq, extra)
        require(bytes.size > 10) { "command not encoded" }
        val key = ((bytes[9].toInt() and 0xFF) shl 8) or (bytes[10].toInt() and 0xFF)
        pairingHold.remove(key)
        ble.send(bytes)
        return waitFrame(listOf(key), timeoutMs).payload
    }

    /**
     * A camera a setup left in station role has its access point down. `07/48 00` is the
     * reset Multiview sends on close. A missing or refused reply is not fatal: an access
     * point already up still serves the normal join.
     */
    private suspend fun restoreCameraAccessPoint() {
        val reply = runCatching { exchangeBle(DjiNative.CMD_MULTICAM_STATION_MODE, "0") }
            .onFailure { if (it is kotlinx.coroutines.CancellationException && it !is TimeoutCancellationException) throw it }
            .getOrNull()
        val accepted = reply?.contentEquals(byteArrayOf(0)) == true || reply?.contentEquals(byteArrayOf(0, 0)) == true
        DjiLog.log("info", "session", "wifi", "wifi: restore camera access point accepted=$accepted")
        // Join only once `07/39` reports 00 00 (access point; 00 01 is station). iOS saw
        // 0.2 to 2.4 s on a Pocket 4 Pro.
        val started = SystemClock.elapsedRealtime()
        for (poll in 0 until 15) {
            val role = runCatching { exchangeBle(DjiNative.CMD_MULTICAM_WIFI_WORK_MODE, timeoutMs = 4_000) }
                .onFailure { if (it is kotlinx.coroutines.CancellationException && it !is TimeoutCancellationException) throw it }
                .getOrNull()
            DjiLog.log("info", "session", "wifi",
                "wifi: camera role after restore ${role?.let(::hexBytes) ?: "no reply"} at " +
                    "${"%.1f".format(Locale.US, (SystemClock.elapsedRealtime() - started) / 1000.0)} s")
            if (role?.contentEquals(byteArrayOf(0, 0)) == true) break
            delay(1_000)
        }
    }

    /**
     * Moves the camera onto the operator's Wi-Fi or this phone's hotspot with the captured
     * Multiview sequence, then goes live on the address that proves this body. Returns the
     * network name.
     */
    private suspend fun runStation(camera: FoundCamera): String {
        val network = stationNetwork
            ?: error("this setup's password is missing on this phone. Edit the setup and enter it again")
        val hotspot = connectionSetup == CameraConnectionSetup.PHONE_HOTSPOT
        publishPhase(ConnectionPhase.JOINING_WIFI)
        station.hotspot = hotspot
        try {
            // Neither setup keeps the phone on a camera access point.
            joiner.release()
            joinedSSID = null
            // Wi-Fi: this phone joins first. Hotspot: the phone hosts it and joins nothing.
            if (!hotspot) {
                _setupProgress.value = "Joining ${network.ssid} on this phone"
                if (!station.join(network.ssid, network.password)) {
                    error("this phone could not join the Wi-Fi. Check the password and that the network is in range")
                }
            }
            if (camera.model.family == "nano") {
                _setupProgress.value = "Waking camera Wi-Fi"
                val wake = exchangeBle(DjiNative.CMD_SESSION_5310)
                if (!wake.contentEquals(byteArrayOf(1, 0, 0, 0))) {
                    error("the Nano did not confirm its Wi-Fi wake. Keep it powered on and try again")
                }
                delay(1_000)
            }
            val identity = readStationIdentity()
            val support = camera.multicamSupport()
            val outcome = StationJoin(
                ssid = network.ssid, password = network.password, hotspot = hotspot,
                hasPreview = support.preview, missingRoleQueryE0 = support.missingRoleQueryE0,
                // Bodies without a captured preview profile (Action, 360) take Multiview's
                // bounded experimental path: no Pocket video-mode route, missing role getter allowed.
                experimental = !camera.hasMultiviewPreview,
                probeExistingStation = true,
            ).run(
                identity,
                exchange = { kind, extra, timeoutMs -> exchangeBle(kind, extra, timeoutMs) },
                send = { kind ->
                    stationSeq = (stationSeq + 1) and 0xFFFF
                    ble.send(DjiNative.command(kind, stationSeq))
                },
                status = { _setupProgress.value = it },
                hotspotReady = { station.address(true) != null },
                verifyOnNetwork = { openStationDatalink(camera, identity, patienceMs = 0) },
                log = ::stationLog,
            )
            if (outcome == StationJoin.Outcome.JOINED) {
                _setupProgress.value = "Finding the camera on ${network.ssid}"
                // A router hands the camera an address, then its services start: about 40 s
                // after the join on a Pocket 4 Pro on a home /24 (iOS, 2026-09-24).
                if (!openStationDatalink(camera, identity, patienceMs = STATION_FIND_MS)) {
                    error(
                        "the camera joined the Wi-Fi, but this phone cannot reach it there. The router is keeping " +
                            "the two apart: on a Wi-Fi 7 router turn off MLO for this network (or add a camera " +
                            "network without it), and turn off client isolation. The Hotspot setup avoids the router",
                    )
                }
            }
            return network.ssid
        } finally {
            _setupProgress.value = null
        }
    }

    /**
     * `07/07` over BLE: the only proof that a LAN address is this body. A Pocket just
     * returned to its access point ignored it until one `53/10` wake (Multiview, 2026-09-23).
     */
    private suspend fun readStationIdentity(): ByteArray =
        try {
            exchangeBle(DjiNative.CMD_GET_WIFI_SSID)
        } catch (_: TimeoutCancellationException) {
            stationLog("identity reply missing; sending Wi-Fi wake once")
            try {
                exchangeBle(DjiNative.CMD_SESSION_5310, timeoutMs = 2_000)
            } catch (_: TimeoutCancellationException) {
            }
            delay(600)
            exchangeBle(DjiNative.CMD_GET_WIFI_SSID)
        }

    /** Sweep the setup's subnet until the camera answers with [identity] or [patienceMs] runs out. */
    private suspend fun openStationDatalink(camera: FoundCamera, identity: ByteArray, patienceMs: Long): Boolean {
        val deadline = SystemClock.elapsedRealtime() + patienceMs
        var sweep = 0
        do {
            sweep += 1
            if (openStationDatalinkOnce(camera, identity, sweep)) return true
            if (SystemClock.elapsedRealtime() >= deadline) break
            delay(2_000)
        } while (SystemClock.elapsedRealtime() < deadline)
        return false
    }

    /**
     * An address counts only when its datalink answers `07/07` with the identity read over
     * BLE: other cameras can share the network. Then register and send the one enable.
     */
    private suspend fun openStationDatalinkOnce(camera: FoundCamera, identity: ByteArray, sweep: Int): Boolean {
        val hotspot = connectionSetup == CameraConnectionSetup.PHONE_HOTSPOT
        if (station.address() == null) {
            stationLog("sweep $sweep no ${if (hotspot) "hotspot" else "Wi-Fi"} address")
            return false
        }
        val known = listOfNotNull(stationHost)
        val started = SystemClock.elapsedRealtime()
        val found = try {
            MultiviewDiscovery(station).candidates(emptySet())
        } catch (error: kotlinx.coroutines.CancellationException) {
            throw error
        } catch (error: Exception) {
            stationLog("sweep $sweep cannot scan this subnet (${error.message})")
            emptyList()
        }
        // Whether the phone is on the setup's network, never its name: diagnostics are shared.
        stationLog("sweep $sweep answering=${found.size} known=${known.size} in " +
            "${"%.1f".format(Locale.US, (SystemClock.elapsedRealtime() - started) / 1000.0)} s")
        for (host in known + found.filterNot { it in known }) {
            coroutineContext.ensureActive()
            disposeDatalink()
            val dl = makeDatalink(camera, host)
            try {
                withTimeout(LiveViewEnablePolicy.handshakeOpenTimeoutMs()) {
                    interruptibleDatalinkOpen { dl.open(identityOnly = true) }
                }
                pairingHold.remove(IDENTITY_KEY)
                dl.sendCommand(DjiNative.CMD_GET_WIFI_SSID)
                val reply = waitFrame(listOf(IDENTITY_KEY), 8_000)
                if (!reply.payload.contentEquals(identity) || datalink !== dl) {
                    stationLog("an answering device is another camera")
                    continue
                }
            } catch (_: TimeoutCancellationException) {
                stationLog("an answering device did not open the datalink")
                continue
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (_: Exception) {
                stationLog("an answering device did not open the datalink")
                continue
            }
            stationLog("camera identity verified on the network")
            stationHost = host
            withContext(Dispatchers.IO) { dl.completeRegistration() }
            // Subscribe is fire-and-forget; an enable in the same burst is ignored.
            delay(STATION_SUBSCRIBE_SETTLE_MS)
            publishPhase(ConnectionPhase.LIVE)
            beginFeedIncidentSession()
            withContext(Dispatchers.IO) { sendCapturedLiveView("first picture") }
            return true
        }
        disposeDatalink()
        return false
    }

    /** New driver on the camera access point, or the verified station address. Becomes [datalink]. */
    private fun makeDatalink(camera: FoundCamera, host: String?): DatalinkDriver =
        DatalinkDriver(
            cameraPath,
            camera.model.datalinkPort,
            camera.model.tcpPoke,
            camera.model.pairingToken,
            cadence,
            videoHistory,
            camera.model,
            debugVideoPacketAdmission =
                if (appHost.debugBuild) { { debugVideoPacketAdmission?.invoke() ?: true } } else null,
            host = host ?: DatalinkDriver.CAMERA_HOST,
        ).also { created ->
            val inputOwner = decoder.claimInputOwner()
            created.onVideoEpochChanged = { epoch -> decoder.advanceInputEpoch(inputOwner, epoch) }
            created.onStatusFrame = { frame -> ingestDatalinkFrame(frame) }
            created.onAccessUnit = { au, epoch ->
                if (LiveViewEnablePolicy.shouldIngestLiveVideo(
                        ingestArmed = true,
                        browsingMedia = isBrowsingMedia,
                        operatorOverlayHeld = operatorOverlayHeld,
                    )
                ) {
                    rawAccessUnits += 1
                    decoder.decode(au, inputOwner, epoch)
                }
            }
            created.onReferenceDiscontinuity = { epoch ->
                decoder.noteReferenceDiscontinuity(inputOwner, epoch)
            }
            datalink = created
        }

    /** Stay on LIVE while recovering so the monitor (last frame) is not unmounted. */
    private fun publishPhase(next: ConnectionPhase) {
        if (holdsMonitor && _phase.value == ConnectionPhase.LIVE && next != ConnectionPhase.IDLE) return
        _phase.value = next
    }

    private fun startFrameRouter() {
        frameJob?.cancel()
        frameJob =
            scope.launch {
                ble.frames.collect { frame ->
                    lastBleNotifyAt = SystemClock.elapsedRealtime()
                    if (frame.cmdSet == 0x07 && frame.cmdId == 0x46 && frame.flags == DjiNative.FLAG_REQUEST) {
                        ble.send(DjiNative.command(DjiNative.CMD_PAIR_APPROVAL_ACK, frame.seq))
                    }
                    // Pid 0x38 GET is untracked. Completing the shared 0x8E waiter
                    // here stole Flip replies as audio/glamour ACKs.
                    if (CameraCommands.isSelfieFlipGetReply(frame.cmdSet, frame.cmdId, frame.payload)) {
                        ingestDatalinkFrame(frame)
                        return@collect
                    }
                    val waiter = waiters[frame.key]
                    if (waiter != null) {
                        waiter.keys.forEach { waiters.remove(it) }
                        waiter.resume(frame)
                    } else if (shouldHold(frame)) {
                        pairingHold[frame.key] = frame
                    }
                }
            }
    }

    private suspend fun completePairing() {
        val frame = waitFrame(matching = listOf(0x0745, 0x0746), timeoutMs = 90_000)
        if (frame.cmdSet == 0x07 && frame.cmdId == 0x45 && frame.payload.size >= 2 && frame.payload[1] == 0x02.toByte()) {
            waitFrame(0x07, 0x46, 90_000)
        }
    }

    private suspend fun waitFrame(set: Int, cmd: Int, timeoutMs: Long): DumlFrame =
        waitFrame(matching = listOf(((set and 0xFF) shl 8) or (cmd and 0xFF)), timeoutMs = timeoutMs)

    private suspend fun waitFrame(matching: List<Int>, timeoutMs: Long): DumlFrame {
        for (key in matching) {
            pairingHold.remove(key)?.let { return it }
        }
        return withTimeout(timeoutMs) {
            suspendCancellableCoroutine { cont ->
                val waiter = FrameWaiter(matching.toSet(), cont)
                matching.forEach { waiters[it] = waiter }
                cont.invokeOnCancellation { matching.forEach { waiters.remove(it) } }
            }
        }
    }

    private fun failAllWaiters(error: Throwable) {
        val pending = waiters.values.distinct()
        waiters.clear()
        pending.forEach { it.resumeWithException(error) }
    }

    private fun startKeepalive(ssid: String?) {
        keepaliveJob?.cancel()
        keepaliveJob =
            scope.launch {
                while (true) {
                    ble.send(DjiNative.command(DjiNative.CMD_SESSION_KEEPALIVE, 0x802B))
                    val live = _phase.value == ConnectionPhase.LIVE && datalink != null
                    if (ssid != null && !holdsMonitor && !isBrowsingMedia && !mediaReturnPending &&
                        shouldStartUDPRebuild
                    ) {
                        endGimbalStick()
                        startFeedRecovery {
                            rebuildDatalinkKeepingPicture("keepalive UDP repair")
                        }
                    }
                    // The camera stops video ~10 s after the last app registration
                    // and ignores enables until a new handshake (Pocket 4 Pro RVI,
                    // 2026-09-22). No UI or repair state may gate this heartbeat.
                    if (ssid != null || live) {
                        withContext(Dispatchers.IO) { datalink?.keepalive() }
                    }
                    val window = cadence.takeKeepaliveWindow(live, isBrowsingMedia)
                    followCameraGallery()
                    if (live && !isBrowsingMedia) {
                        publishPipelineStats()
                        noteFeedIncidentSnapshot(window)
                        window?.let { lineWindow ->
                            withContext(Dispatchers.IO) {
                                DjiLog.log("info", "feed", "cadence",
                                    "${cadence.format(lineWindow)} incomplete=${datalink?.droppedIncomplete ?: 0} " +
                                        "errors=${decoder.decoderErrors.get()} phase=${_phase.value.name.lowercase()} " +
                                        "irap=${datalink?.admissionIrapSeen ?: 0} ps=${datalink?.admissionParameterSetsSeen ?: 0} " +
                                        "gate=${if (datalink?.admissionAwaitingRandomAccess == true) "await" else "open"} " +
                                        "gateDrops=${datalink?.admissionGateDrops ?: 0} " +
                                        "dec=cfg:${decoder.isConfigured},hold:${decoder.awaitingIdr}," +
                                        "surface:${decoder.isPresentationReady}")
                            }
                        }
                        recoverLiveViewIfNeeded()
                    }
                    if (ssid != null && !holdsMonitor && live && !isBrowsingMedia) {
                        val rxAge =
                            lastSelfieFlipReplyElapsed.takeIf { it > 0 }?.let {
                                SystemClock.elapsedRealtime() - it
                            }
                        if (rxAge == null || rxAge >= 2_000L) {
                            ble.send(DjiNative.command(DjiNative.CMD_GET_SELFIE_FLIP))
                        }
                    }
                    delay(1_000)
                }
            }
    }

    /** One UDP rebuild at a time. Keepalive must not collide with first-picture. */
    private val shouldStartUDPRebuild: Boolean
        get() {
            val now = SystemClock.elapsedRealtime()
            val videoAge = datalink?.lastVideoPacketAt?.let { now - it }
            val sinceEnable = if (lastIdrRequest == 0L) null else now - lastIdrRequest
            if (LiveViewEnablePolicy.shouldHoldForGopReset(sinceEnable, videoAge)) return false
            if (FocusTrackMode.shouldHoldWatchdog(lastFocusTrackAt?.let { (now - it) / 1000.0 })) {
                return false
            }
            if (CamFov.shouldHoldWatchdog(
                    lastZoomActivityAt?.let { (now - it) / 1000.0 },
                    zoomPinchPreview != null,
                )
            ) {
                return false
            }
            if (CameraCommands.shouldHoldGimbalWatchdog(
                    lastGimbalThrowAt?.let { (now - it) / 1000.0 },
                    videoAge?.div(1000.0),
                    gimbalStickHeld,
                )
            ) {
                return false
            }
            if (CameraCommands.shouldHoldCameraSetWatchdog(
                    lastCameraSetAt?.let { (now - it) / 1000.0 },
                    videoAge?.div(1000.0),
                )
            ) {
                return false
            }
            val videoFresh = videoAge != null && videoAge < LiveViewEnablePolicy.STALL_MS
            val statusFresh =
                datalink?.lastStatusAt?.let { now - it < LiveViewEnablePolicy.STALL_MS } == true
            return LiveViewEnablePolicy.shouldKeepaliveRebuildUDP(
                flowNeedsRebuild = datalink?.needsRebuild == true,
                rebuildInFlight = datalink?.isRebuilding == true || feedRecoveryJob != null,
                sinceRebuildMs = datalink?.lastRebuildAt?.let { now - it },
                videoFresh = videoFresh,
                sawPicture = hasStableLivePicture,
                statusFresh = statusFresh,
                sinceEnableMs = if (lastIdrRequest == 0L) null else now - lastIdrRequest,
                pathReady = cameraPath.isProcessBound(),
            )
        }

    private val hasStableLivePicture: Boolean
        get() {
            val at = decoder.lastPresentedAt ?: return false
            return SystemClock.elapsedRealtime() - at >= LiveViewEnablePolicy.REBUILD_COOLDOWN_MS
        }

    /** iOS parity: one incident session per operator connect; recovery reconnects keep it. */
    private fun beginFeedIncidentSession() {
        if (incidentSessionActive) return
        incidentSessionActive = true
        incidentSource = appHost.incidents.beginBoundSession(
            appHost.incidentSessionContext(feedSessionId, connectedCamera?.model?.family ?: "none",
                decoderGeneration = decoder.randomAccess.generation, socketGeneration = socketGeneration),
        )
    }

    private fun noteFeedIncidentSnapshot(window: LivePipelineCadence.Window?) {
        val source = incidentSource ?: return
        val now = SystemClock.elapsedRealtime()
        val ingressSource = datalink
        fun ageSec(at: Long?): Double? = FeedIncidentRateSampler.ageMilliseconds(at, now)
        val hz = window?.hz
        source.ingestSnapshot(
            FeedIncidentSnapshot(
                monotonicNow = now / 1000.0,
                wallClockMs = System.currentTimeMillis(),
                rates =
                    FeedIncidentRateObservation(
                        packetHz = hz?.get(LivePipelineCadence.Stage.VIDEO),
                        accessUnitHz = hz?.get(LivePipelineCadence.Stage.AU),
                        decodeSubmitHz = hz?.get(LivePipelineCadence.Stage.SUBMIT),
                        decodeAcceptHz = hz?.get(LivePipelineCadence.Stage.SUBMIT),
                        decodedOutputHz = hz?.get(LivePipelineCadence.Stage.OUTPUT),
                        // Scopes tap presented GLES frames; there is no independent assist-output stage.
                        presentHz = hz?.get(LivePipelineCadence.Stage.PRESENT),
                        ackHz = hz?.get(LivePipelineCadence.Stage.ACK),
                    ).rates(),
                ages =
                    FeedIncidentAges(
                        packetAge = ageSec(datalink?.lastVideoPacketAt),
                        accessUnitAge = ageSec(datalink?.lastAccessUnitAt),
                        decodeAcceptAge = decoder.lastDecoderAcceptedAt?.takeIf { it <= now }?.let(::ageSec),
                        decodedOutputAge = ageSec(decoder.lastDecoderOutputAt),
                        assistOutputAge = null,
                        presentAge = ageSec(decoder.lastPresentedAt),
                        statusAge = ageSec(ingressSource?.lastStatusAt),
                    ),
                queue =
                    FeedIncidentQueue(
                        bytes = datalink?.pendingAccessUnitBytes ?: 0,
                        count = datalink?.pendingAccessUnits ?: 0,
                        incompleteAccessUnits = datalink?.droppedIncomplete ?: 0,
                        drops = datalink?.admissionDrops ?: 0,
                    ),
                decoder =
                    decoder.incidentDecoder(nowElapsedMs = now),
                lifecycle =
                    FeedIncidentLifecycle(
                        foreground = !needsForegroundRecover,
                        playbackActive = _status.value.inPlayback,
                        connected = _phase.value == ConnectionPhase.LIVE,
                        liveEstablished = decoder.lastPresentedAt != null,
                        // Thermal and battery saver separate a throttled presenter from a stall
                        // (S1 telemetry gap on presentStalled; iOS already sends both).
                        thermalState = FeedIncidentThermal.fromAndroidThermalStatus(power?.currentThermalStatus),
                        lowPower = power?.isPowerSaveMode == true,
                        sceneActive = !needsForegroundRecover,
                        assistState = "off",
                        outputObservable = decoder.decoderOutputExpected,
                        presentationExpected = decoder.isPresentationReady && decoder.lastPresentedAt != null,
                    ),
                ingress = ingressSource?.ingressSnapshot(now / 1000.0),
                watchdogGate = watchdogGate,
            ),
        )
        source.noteDecoderGeneration(decoder.randomAccess.generation)
    }

    private fun publishPipelineStats() {
        videoPackets = datalink?.videoPackets ?: 0
        accessUnits = rawAccessUnits
        framesEnqueued = decoder.framesEnqueued.get()
        droppedIncomplete = datalink?.droppedIncomplete ?: 0
        decoderErrors = decoder.decoderErrors.get()
        hasVideoFormat = decoder.hasFormat
        nalTypes = decoder.nalTypesSeen.ifEmpty { "—" }
        val keyframe = decoder.lastKeyframeAt
        lastKeyframeAge =
            if (keyframe == null) "none yet"
            else String.format(Locale.US, "%.1fs", (System.currentTimeMillis() - keyframe) / 1000.0)
    }

    /** 0x09/0xa8 is live-start and the only PLI; 1 Hz spam resets the GOP and blacks the feed. */
    /**
     * 1 Hz. Playback before any picture is stray and keeps the exit; playback
     * after picture is the operator opening the camera's gallery, which used to
     * be kicked back to live within a second.
     */
    private fun followCameraGallery() {
        val live = _phase.value == ConnectionPhase.LIVE
        if (live && decoder.lastPresentedAt != null && _status.value.inPlayback) {
            cameraGalleryAwayTicks = 0
            if (!_cameraGalleryOpen.value) {
                DjiLog.log("info", "media", "gallery", "media: camera gallery open — following")
                _cameraGalleryOpen.value = true
            }
        } else if (_cameraGalleryOpen.value) {
            cameraGalleryAwayTicks += 1
            if (cameraGalleryAwayTicks >= 3 || !live) {
                DjiLog.log("info", "media", "gallery", "media: camera gallery closed — returning to live")
                _cameraGalleryOpen.value = false
            }
        }
    }

    private fun recoverLiveViewIfNeeded() {
        if (isBrowsingMedia || mediaReturnPending || holdsMonitor) {
            logRecoverSkip(if (isBrowsingMedia || mediaReturnPending) "browsing" else "holdsMonitor")
            return
        }
        if (needsForegroundRecover) {
            logRecoverSkip("foreground")
            return
        }
        if (!cameraPath.isProcessBound()) {
            logRecoverSkip("unbound")
            return
        }
        if (feedRecoveryJob != null) {
            logRecoverSkip("recoveryJob")
            return
        }
        // Media opens on the next UI pass; the stray exit and repairs must not fight it.
        if (_cameraGalleryOpen.value) return
        if (MediaLiveResume.strayPlaybackAction(
                browsing = isBrowsingMedia,
                inPlayback = _status.value.inPlayback,
            ) != null
        ) {
            datalink?.exitPlayback()
            Log.i(TAG, "media: stray playback — sent exit")
            val hasPicture = decoder.lastPresentedAt != null
            if (!LiveViewEnablePolicy.shouldContinueFirstPictureAfterStrayPlayback(hasPicture)) {
                return
            }
        }
        val packets = datalink?.videoPackets ?: 0
        val now = SystemClock.elapsedRealtime()
        if (packets > 0 && streamStartedAt == null) streamStartedAt = now
        val presentedAge = decoder.lastPresentedAt?.let { now - it }
        if (!firstPictureSettled &&
            LiveViewEnablePolicy.shouldMarkFirstPictureSettled(
                presentedAgeMs = presentedAge,
                sinceEnableMs = if (lastIdrRequest == 0L) Long.MAX_VALUE else now - lastIdrRequest,
            )
        ) {
            firstPictureSettled = true
            if (focusTrackPending) {
                focusTrackPending = false
                refreshFocusTrack()
            }
        }
        if (LiveViewEnablePolicy.shouldRunFirstPictureRecover(
                presentedAgeMs = presentedAge,
                alreadySettled = firstPictureSettled,
            )
        ) {
            recoverFirstPictureIfNeeded(now, packets)
            return
        }
        applyFeedWatchdog(now, packets)
    }

    private fun resetFirstPictureFormatPoke() {
        firstPictureFormatPokeJob?.cancel()
        firstPictureFormatPokeJob = null
        firstPictureFormatPoked = false
    }

    private fun startFirstPictureFormatPoke() {
        if (firstPictureFormatPokeJob?.isActive == true) return
        firstPictureFormatPokeJob =
            scope.launch {
                try {
                    runFirstPictureFormatPoke()
                } finally {
                    firstPictureFormatPokeJob = null
                }
            }
    }

    private suspend fun runFirstPictureFormatPoke() {
        val live = _status.value
        if (live.isRecording || isBrowsingMedia) return
        val original = VideoFormat.firstPictureOriginal(live)
        val kick = VideoFormat.firstPictureEncoderKick(original, live.availableVideoFormats)
        firstPictureFormatPoked = true
        val legal = live.availableVideoFormats.isEmpty() || kick in live.availableVideoFormats
        Log.i(
            TAG,
            "live: Pocket 3 first-picture format poke ${original.chipLabel} → " +
                "${kick.chipLabel} → ${original.chipLabel} legal=${if (legal) 1 else 0} " +
                "formats=${live.availableVideoFormats.size}",
        )
        setVideoFormat(kick, fromOperator = false)
        waitForRecordingFormatPokeSettle()
        if (!coroutineContext.isActive) return
        setVideoFormat(original, fromOperator = false)
        waitForRecordingFormatPokeSettle()
        if (!coroutineContext.isActive || isBrowsingMedia) return
        sendCapturedLiveView("first-picture format poke")
    }

    private suspend fun waitForRecordingFormatPokeSettle() {
        val start = SystemClock.elapsedRealtime()
        while (formatPin != null &&
            SystemClock.elapsedRealtime() - start < LiveViewEnablePolicy.FORMAT_STALL_MS
        ) {
            delay(50)
        }
        val elapsed = SystemClock.elapsedRealtime() - start
        val min = LiveViewEnablePolicy.FORMAT_POKE_MIN_SETTLE_MS
        if (elapsed < min) delay(min - elapsed)
    }

    private fun recoverFirstPictureIfNeeded(
        now: Long, packets: Int, currentRepairOwnsPicture: Boolean = false,
    ) {
        if (datalink?.isRebuilding == true || (feedRecoveryJob != null && !currentRepairOwnsPicture)) return
        val sinceEnable = if (lastIdrRequest == 0L) 0L else now - lastIdrRequest
        val step =
            LiveViewEnablePolicy.firstPictureStep(
                videoPackets = packets,
                enableSends = liveViewEnableSends,
                sinceEnableMs = sinceEnable,
                videoAgeMs = datalink?.lastVideoPacketAt?.let { now - it },
                sinceRebuildMs = datalink?.lastRebuildAt?.let { now - it },
                needsRecordingFormatPoke =
                    connectedCamera?.model?.needsFirstPictureFormatPoke == true,
                alreadyPokedRecordingFormat = firstPictureFormatPoked,
                recordingFormatPokeInFlight = firstPictureFormatPokeJob?.isActive == true,
                isRecording = _status.value.isRecording,
                hasPresentedPicture =
                    decoder.lastPresentedAt?.let { now - it }?.let { it >= 0 && it < LiveViewEnablePolicy.STALL_MS }
                        == true,
            )
        val live = _status.value
        val deferPoke =
            step == LiveViewEnablePolicy.FirstPictureStep.POKE_RECORDING_FORMAT &&
                LiveViewEnablePolicy.shouldDeferRecordingFormatPoke(
                    hasKnownRecordingFormat = VideoFormat.hasKnownRecordingFormat(live),
                    sinceEnableMs = sinceEnable,
                )
        logFirstPicture(now, packets, step, deferPoke)
        when (step) {
            LiveViewEnablePolicy.FirstPictureStep.WAIT -> {}
            LiveViewEnablePolicy.FirstPictureStep.POKE_RECORDING_FORMAT -> {
                if (!deferPoke) startFirstPictureFormatPoke()
            }
            LiveViewEnablePolicy.FirstPictureStep.RESEND_ENABLE -> {
                // Do not route through sendRecoverEnable; inPlayback / decoder-ready
                // holds skipped the only PLI and sat on WAITING FOR LIVE VIEW.
                val resend = liveViewEnableSends > 0
                if (sendCapturedLiveView(if (resend) "first-picture resend" else "first picture") && resend) {
                    logRecovery(RecoveryAction.ENABLE, RecoveryEffect.SENT, RecoveryReason.FIRST_PICTURE)
                }
            }
            LiveViewEnablePolicy.FirstPictureStep.REBUILD_UDP -> {
                if (currentRepairOwnsPicture) return
                val videoAge = datalink?.lastVideoPacketAt?.let { now - it }
                val noPicture = decoder.lastPresentedAt == null && !decoder.hasFormat
                if (LiveViewEnablePolicy.shouldKeepUdpForLeftoverGop(
                        noPicture = noPicture,
                        videoPackets = packets,
                        videoAgeMs = videoAge,
                    )
                ) {
                    Log.i(
                        TAG,
                        "live: leftover GOP without picture pkts=$packets " +
                            "lastVideo=${videoAge}ms — resend enable, keep UDP",
                    )
                    sendCapturedLiveView("first-picture leftover GOP")
                    return
                }
                Log.i(TAG, "live: first-picture rebuild UDP (receive died pkts=$packets)")
                startFeedRecovery {
                    rebuildDatalinkKeepingPicture("first-picture after UDP rebuild")
                }
            }
            LiveViewEnablePolicy.FirstPictureStep.REJOIN -> {
                if (currentRepairOwnsPicture) return
                Log.i(TAG, "live: first-picture full rejoin (SoftAP bind kept)")
                startFeedRecovery { rejoinDatalinkKeepingLive() }
            }
        }
    }

    private fun applyFeedWatchdog(now: Long, packets: Int) {
        val shellHold =
            when {
                needsForegroundRecover -> "foregroundRecover"
                datalink?.isRebuilding == true -> "endpointRebuild"
                feedRecoveryJob != null -> "repairInFlight"
                else -> null
            }
        if (shellHold != null) {
            watchdogGate =
                FeedIncidentWatchdogGate(
                    pathReady = cameraPath.isProcessBound(),
                    repairReady = decoder.isPresentationReady,
                    outputExpected = decoder.decoderOutputExpected,
                    hold = shellHold,
                )
            return
        }
        val pictureOwner = mediaPictureGeneration
        val repairLink = datalink
        val decoderInput = decoder.captureInputOwnership()
        val videoAgeMs = datalink?.lastVideoPacketAt?.let { now - it }
        val snap =
            LiveViewEnablePolicy.Snapshot(
                now = now,
                videoPackets = packets,
                lastVideoPacketAt = datalink?.lastVideoPacketAt,
                lastAccessUnitAt = datalink?.lastAccessUnitAt,
                lastStatusAt = datalink?.lastStatusAt,
                lastBleNotifyAt = lastBleNotifyAt,
                lastRebuildAt = datalink?.lastRebuildAt,
                lastEnableAt = lastIdrRequest,
                pathReady = cameraPath.isProcessBound(),
                hasFormat = decoder.hasFormat,
                decoderErrors = decoderErrors,
                live = _phase.value == ConnectionPhase.LIVE,
                sawPicture = decoder.lastPresentedAt != null,
                hadVideo = videoHistory.hadVideo(packets, videoAgeMs),
                lastFocusTrackAt = lastFocusTrackAt,
                lastZoomAt = lastZoomActivityAt,
                zoomPinchActive = zoomPinchPreview != null,
                lastGimbalThrowAt = lastGimbalThrowAt,
                gimbalStickHeld = gimbalStickHeld,
                lastCameraSetAt = lastCameraSetAt,
                lastDecoderOutputAt = decoder.lastDecoderOutputAt,
                lastPresentedAt = decoder.lastPresentedAt,
                decoderOutputExpected = decoder.decoderOutputExpected,
                referenceRecoveryNeeded = decoder.referenceRecoveryNeeded,
                lastIrapAt = decoder.lastIrapAt,
                repairReady = decoder.isPresentationReady,
            )
        if (coreWatchdog == 0L && DjiNative.isAvailable) {
            coreWatchdog = DjiNative.feedWatchdogCreate()
        }
        if (coreWatchdog != 0L) {
            val nowSec = now / 1000.0
            fun age(at: Long?): Double? {
                if (at == null || at <= 0L) return null
                return (now - at) / 1000.0
            }
            val json =
                buildString {
                    append("{")
                    append("\"now\":$nowSec")
                    append(",\"flowHealthy\":${snap.pathReady && datalink?.needsRebuild != true}")
                    append(",\"pathReady\":${snap.pathReady}")
                    append(",\"hasFormat\":${decoder.hasFormat}")
                    append(",\"decoderFailed\":${decoder.failedThisGeneration}")
                    append(",\"live\":${_phase.value == ConnectionPhase.LIVE}")
                    append(",\"sawPicture\":${decoder.lastPresentedAt != null}")
                    append(",\"tcpPokeReady\":${datalink?.isTcpPokeReady == true}")
                    append(",\"hadVideo\":${videoHistory.hadVideo(packets, videoAgeMs)}")
                    age(decoder.lastPresentedAt)?.let { append(",\"lastDecodedFrameAge\":$it") }
                    age(datalink?.lastVideoPacketAt)?.let { append(",\"lastVideoPacketAge\":$it") }
                    age(datalink?.lastAccessUnitAt)?.let { append(",\"lastAccessUnitAge\":$it") }
                    age(datalink?.lastStatusAt)?.let { append(",\"lastStatusAge\":$it") }
                    age(lastBleNotifyAt)?.let { append(",\"lastBleNotifyAge\":$it") }
                    age(datalink?.lastRebuildAt)?.let { append(",\"secondsSinceLastRebuild\":$it") }
                    age(lastIdrRequest.takeIf { it > 0L })?.let { append(",\"secondsSinceLastEnable\":$it") }
                    age(lastFocusTrackAt)?.let { append(",\"secondsSinceFocusTrackSet\":$it") }
                    age(lastZoomActivityAt)?.let { append(",\"secondsSinceZoomSet\":$it") }
                    append(",\"zoomPinchActive\":${zoomPinchPreview != null}")
                    age(lastGimbalThrowAt)?.let { append(",\"secondsSinceGimbalThrow\":$it") }
                    append(",\"gimbalStickHeld\":$gimbalStickHeld")
                    age(lastCameraSetAt)?.let { append(",\"secondsSinceCameraSet\":$it") }
                    age(decoder.lastDecoderOutputAt)?.let { append(",\"lastDecoderOutputAge\":$it") }
                    append(",\"decoderOutputExpected\":${decoder.decoderOutputExpected}")
                    append(",\"referenceRecoveryNeeded\":${snap.referenceRecoveryNeeded}")
                    age(decoder.lastIrapAt)?.let { append(",\"secondsSinceLastIrap\":$it") }
                    append(",\"repairReady\":${decoder.isPresentationReady}")
                    append("}")
                }
            val action = DjiNative.feedWatchdogTick(coreWatchdog, json)
            watchdogGate =
                FeedIncidentWatchdogGate(
                    pathReady = snap.pathReady,
                    repairReady = snap.repairReady,
                    outputExpected = snap.decoderOutputExpected,
                    hold = DjiNative.feedWatchdogTick(coreWatchdog, "{\"lastHold\":true}")?.takeIf { it.isNotEmpty() },
                )
            when (action) {
                "resendLiveViewEnable" -> {
                    endGimbalStick()
                    logRecovery(RecoveryAction.ENABLE, RecoveryEffect.REQUESTED, RecoveryReason.WATCHDOG)
                    datalink?.reRegister()
                    if (!sendRecoverEnable(force = true, reason = "watchdog")) {
                        DjiNative.feedWatchdogTick(coreWatchdog, "{\"rollbackLastAction\":true}")
                    }
                }
                "rebuildVTSession" -> {
                    endGimbalStick()
                    val watchdogHandle = coreWatchdog
                    startFeedRecovery {
                        if (!ownsLivePicture(pictureOwner) || datalink !== repairLink) return@startFeedRecovery
                        rebuildDecoderKeepingPicture(snap.referenceRecoveryNeeded, decoderInput) {
                            if (coreWatchdog == watchdogHandle) {
                                DjiNative.feedWatchdogTick(watchdogHandle, "{\"rollbackLastAction\":true}")
                            }
                        }
                    }
                }
                "reopenDatalink" -> {
                    endGimbalStick()
                    logRecovery(RecoveryAction.ENDPOINT, RecoveryEffect.REQUESTED, RecoveryReason.WATCHDOG)
                    startFeedRecovery {
                        rebuildDatalinkKeepingPicture("feed watchdog UDP rebuild")
                    }
                }
                "fullSessionRejoin" -> {
                    endGimbalStick()
                    Log.i(TAG, "feed: watchdog full datalink rejoin")
                    logRecovery(RecoveryAction.REJOIN, RecoveryEffect.REQUESTED, RecoveryReason.WATCHDOG)
                    startFeedRecovery { rejoinDatalinkKeepingLive() }
                }
                else -> applyWatchdogNone(snap)
            }
            return
        }
        // The JVM fallback ladder does not name its gate: hold stays unknown.
        watchdogGate =
            FeedIncidentWatchdogGate(
                pathReady = snap.pathReady,
                repairReady = snap.repairReady,
                outputExpected = snap.decoderOutputExpected,
            )
        val watchdogBeforeTick = feedWatchdog.capture()
        when (LiveViewEnablePolicy.tick(feedWatchdog, snap)) {
            LiveViewEnablePolicy.Action.NONE -> applyWatchdogNone(snap)
            LiveViewEnablePolicy.Action.RESEND_ENABLE -> {
                endGimbalStick()
                logRecovery(RecoveryAction.ENABLE, RecoveryEffect.REQUESTED, RecoveryReason.WATCHDOG)
                datalink?.reRegister()
                if (!sendRecoverEnable(force = true, reason = "watchdog")) {
                    feedWatchdog.restore(watchdogBeforeTick)
                }
            }
            LiveViewEnablePolicy.Action.REBUILD_DECODER -> {
                endGimbalStick()
                startFeedRecovery {
                    if (!ownsLivePicture(pictureOwner) || datalink !== repairLink) return@startFeedRecovery
                    rebuildDecoderKeepingPicture(snap.referenceRecoveryNeeded, decoderInput) {
                        feedWatchdog.restore(watchdogBeforeTick)
                    }
                }
            }
            LiveViewEnablePolicy.Action.REBUILD_UDP -> {
                endGimbalStick()
                logRecovery(RecoveryAction.ENDPOINT, RecoveryEffect.REQUESTED, RecoveryReason.WATCHDOG)
                startFeedRecovery {
                    rebuildDatalinkKeepingPicture("feed watchdog UDP rebuild")
                }
            }
            LiveViewEnablePolicy.Action.FULL_REJOIN -> {
                endGimbalStick()
                Log.i(TAG, "feed: watchdog full datalink rejoin")
                logRecovery(RecoveryAction.REJOIN, RecoveryEffect.REQUESTED, RecoveryReason.WATCHDOG)
                startFeedRecovery { rejoinDatalinkKeepingLive() }
            }
        }
    }

    private fun logRecoverSkip(reason: String) {
        val now = SystemClock.elapsedRealtime()
        if (reason == lastRecoverSkipReason && now - lastRecoverSkipAt < 3_000L) return
        lastRecoverSkipReason = reason
        lastRecoverSkipAt = now
        Log.i(
            TAG,
            "live: skip recover ($reason) pkts=${datalink?.videoPackets ?: 0} " +
                "enables=$liveViewEnableSends",
        )
    }

    private fun logFirstPicture(
        now: Long,
        packets: Int,
        step: LiveViewEnablePolicy.FirstPictureStep,
        deferred: Boolean,
    ) {
        val live = _status.value
        val original = VideoFormat.firstPictureOriginal(live)
        val kick = VideoFormat.firstPictureEncoderKick(original, live.availableVideoFormats)
        val known = VideoFormat.hasKnownRecordingFormat(live)
        val legal = live.availableVideoFormats.isEmpty() || kick in live.availableVideoFormats
        val needs = connectedCamera?.model?.needsFirstPictureFormatPoke == true
        val signature =
            "${step.name}.$deferred.$needs.$firstPictureFormatPoked.$known.$packets.$liveViewEnableSends.${decoder.hasFormat}"
        if (signature == lastFirstPictureSignature && now - lastFirstPictureLogAt < 3_000L) return
        lastFirstPictureSignature = signature
        lastFirstPictureLogAt = now
        val videoAge = datalink?.lastVideoPacketAt?.let { now - it }
        val presented = decoder.lastPresentedAt?.let { now - it }
        Log.i(
            TAG,
            "feed: first-picture step=${step.name} defer=${if (deferred) 1 else 0} " +
                "needsPoke=${if (needs) 1 else 0} poked=${if (firstPictureFormatPoked) 1 else 0} " +
                "inFlight=${if (firstPictureFormatPokeJob?.isActive == true) 1 else 0} " +
                "known=${if (known) 1 else 0} model=${connectedCamera?.model?.name ?: "none"} " +
                "boot=${original.chipLabel} kick=${kick.chipLabel} legal=${if (legal) 1 else 0} " +
                "formats=${live.availableVideoFormats.size} enables=$liveViewEnableSends " +
                "videoPkts=$packets lastVideo=${videoAge ?: -1}ms presented=${presented ?: -1}ms " +
                "decoderFmt=${if (decoder.hasFormat) 1 else 0} " +
                "idrHold=${if (decoder.awaitingIdr) 1 else 0}",
        )
    }

    private fun applyWatchdogNone(snap: LiveViewEnablePolicy.Snapshot) {
        maybeReleaseIdrHold(snap)
        logWatchdogHold(snap)
    }

    private fun maybeReleaseIdrHold(snap: LiveViewEnablePolicy.Snapshot) {
        if (!decoder.awaitingIdr) return
        val sinceEnable = if (snap.lastEnableAt == 0L) null else snap.now - snap.lastEnableAt
        if (!LiveViewEnablePolicy.shouldReleaseIDRHold(
                awaitingIDR = true,
                udpReceiveAlive = LiveViewEnablePolicy.udpReceiveAlive(snap),
                sinceEnableMs = sinceEnable,
                hasPresentedPicture = decoder.lastPresentedAt != null,
            )
        ) {
            return
        }
        if (decoder.endIDRHold()) {
            Log.i(TAG, "feed: release IDR hold — UDP alive, picture on layer")
            logRecovery(RecoveryAction.DECODER, RecoveryEffect.SENT, RecoveryReason.UDP_ALIVE)
        }
    }

    private fun logRecovery(action: RecoveryAction, effect: RecoveryEffect, reason: RecoveryReason) {
        val line = RecoveryEffectLog.line(action, effect, reason)
        DjiLog.log("notice", "recovery", effect.wire, line)
        val phase =
            when (effect) {
                RecoveryEffect.REQUESTED -> FeedRepairPhase.REQUESTED
                RecoveryEffect.BLOCKED -> FeedRepairPhase.BLOCKED
                RecoveryEffect.SENT -> FeedRepairPhase.LOCALLY_SENT
                RecoveryEffect.FRESH_PICTURE -> FeedRepairPhase.PICTURE_RESTORED
            }
        incidentSource?.recordRepair(
            FeedRepairRecord(
                monotonicAt = SystemClock.elapsedRealtime() / 1000.0,
                action = action.wire,
                phase = phase,
                reason = reason.wire,
            ),
        )
    }

    private fun logWatchdogHold(snap: LiveViewEnablePolicy.Snapshot) {
        if (LiveViewEnablePolicy.udpReceiveAlive(snap)) return
        val sinceEnable = if (snap.lastEnableAt == 0L) null else snap.now - snap.lastEnableAt
        val videoAge = LiveViewEnablePolicy.age(snap.now, snap.lastVideoPacketAt)
        if (LiveViewEnablePolicy.shouldHoldForGopReset(sinceEnable, videoAge)) {
            Log.i(TAG, LiveViewEnablePolicy.holdUdpRebuildGopLog(sinceEnable, videoAge))
        } else if (
            FocusTrackMode.shouldHoldWatchdog(
                LiveViewEnablePolicy.age(snap.now, snap.lastFocusTrackAt)?.div(1000.0),
            )
        ) {
            Log.i(
                TAG,
                LiveViewEnablePolicy.holdUdpRebuildAfcLog(
                    LiveViewEnablePolicy.age(snap.now, snap.lastFocusTrackAt),
                    videoAge,
                ),
            )
        } else if (
            CamFov.shouldHoldWatchdog(
                LiveViewEnablePolicy.age(snap.now, snap.lastZoomAt)?.div(1000.0),
                snap.zoomPinchActive,
            )
        ) {
            Log.i(
                TAG,
                LiveViewEnablePolicy.holdUdpRebuildZoomLog(
                    LiveViewEnablePolicy.age(snap.now, snap.lastZoomAt),
                    videoAge,
                ),
            )
        }
    }

    private fun sendRecoverEnable(force: Boolean, reason: String): Boolean {
        cancelProgrammedMove()
        endGimbalStick()
        if (isBrowsingMedia) {
            logRecovery(RecoveryAction.ENABLE, RecoveryEffect.BLOCKED, RecoveryReason.MEDIA)
            return false
        }
        if (_status.value.inPlayback) {
            datalink?.exitPlayback()
            Log.i(TAG, "feed: hold enable — camera still in playback ($reason)")
            logRecovery(RecoveryAction.ENABLE, RecoveryEffect.BLOCKED, RecoveryReason.PLAYBACK)
            return false
        }
        val pathReady = cameraPath.isProcessBound()
        val decoderReady = decoder.isPresentationReady
        if (!LiveViewEnablePolicy.shouldSendRecoverEnable(pathReady, decoderReady)) {
            Log.i(TAG, "feed: hold enable path=${if (pathReady) 1 else 0} decoder=${if (decoderReady) 1 else 0} reason=$reason")
            logRecovery(
                RecoveryAction.ENABLE,
                RecoveryEffect.BLOCKED,
                if (!pathReady) RecoveryReason.PATH else RecoveryReason.NOT_READY,
            )
            return false
        }
        if (!force && lastIdrRequest != 0L &&
            SystemClock.elapsedRealtime() - lastIdrRequest < LiveViewEnablePolicy.ESCALATE_MS
        ) {
            logRecovery(RecoveryAction.ENABLE, RecoveryEffect.BLOCKED, RecoveryReason.OVERLAP)
            return false
        }
        return sendCapturedLiveView(reason)
    }

    /** Native decoder rebuild + one owned PLI. Last picture held. Not a second repair owner. */
    private suspend fun rebuildDecoderKeepingPicture(
        referenceLossOnly: Boolean,
        input: DecoderInputOwnership.Token,
        onUnspent: () -> Unit,
    ) {
        val owner = mediaPictureGeneration
        val link = datalink ?: return
        fun ownsPicture() = ownsLivePicture(owner) && datalink === link && !link.isClosed
        val reason = if (referenceLossOnly) RecoveryReason.REFERENCE_LOSS else RecoveryReason.OUTPUT_SILENCE
        logRecovery(RecoveryAction.DECODER, RecoveryEffect.REQUESTED, reason)
        val startedAt = SystemClock.elapsedRealtime()
        val rebuilt = withContext(Dispatchers.IO) { decoder.rebuildPresentationIfNeeded(referenceLossOnly, input) }
        if (!ownsPicture()) return
        if (decoder.captureInputOwnership() != input) return
        if (!rebuilt) {
            // This job excludes subsequent watchdog ticks; its generation/link
            // still own the request. Restore only the unspent action, not idle.
            onUnspent()
            return
        }
        var sent = false
        val readyDeadline = startedAt + LiveViewEnablePolicy.ENDPOINT_PICTURE_GRACE_MS
        fun enableReady() =
            decoder.isPresentationReady &&
                cameraPath.isProcessBound() &&
                !isBrowsingMedia &&
                !_status.value.inPlayback
        while (SystemClock.elapsedRealtime() < readyDeadline) {
            if (!ownsPicture()) return
            if (enableReady()) {
                sent = sendRecoverEnable(force = true, reason = "watchdog decoder")
                if (sent) break
            }
            delay(250)
        }
        if (!sent) {
            logRecovery(RecoveryAction.DECODER, RecoveryEffect.BLOCKED, RecoveryReason.NOT_READY)
            return
        }
        // Resend the keyframe request until an IRAP newer than it lands;
        // unanswered twice, rebuild the endpoint (core decoderRepairStep).
        var keyframeRequests = 1
        var restored = false
        repair@ while (ownsPicture()) {
            if (hasRecoveryPicture(startedAt)) {
                restored = true
                break
            }
            val now = SystemClock.elapsedRealtime()
            when (
                LiveViewEnablePolicy.decoderRepairStep(
                    sinceRepairStartMs = now - startedAt,
                    sinceEnableMs = now - lastIdrRequest,
                    sinceIrapMs = decoder.lastIrapAt?.let { now - it },
                    keyframeRequests = keyframeRequests,
                )
            ) {
                LiveViewEnablePolicy.DecoderRepairStep.WAIT -> Unit
                LiveViewEnablePolicy.DecoderRepairStep.RESEND_KEYFRAME ->
                    if (enableReady() && sendRecoverEnable(force = true, reason = "watchdog keyframe resend")) {
                        keyframeRequests += 1
                    }
                LiveViewEnablePolicy.DecoderRepairStep.REBUILD_ENDPOINT -> {
                    logRecovery(RecoveryAction.ENDPOINT, RecoveryEffect.REQUESTED, RecoveryReason.KEYFRAME_UNANSWERED)
                    rebuildDatalinkKeepingPicture("keyframe unanswered")
                    return
                }
                LiveViewEnablePolicy.DecoderRepairStep.DEADLINE -> break@repair
            }
            delay(100)
        }
        if (!ownsPicture()) return
        if (restored) {
            logRecovery(RecoveryAction.DECODER, RecoveryEffect.FRESH_PICTURE, RecoveryReason.OUTPUT_RESUMED)
            if (coreWatchdog != 0L && DjiNative.isAvailable) DjiNative.feedWatchdogReset(coreWatchdog)
            feedWatchdog.reset()
            return
        }
        val outputAt = decoder.lastDecoderOutputAt
        if (decoder.decoderOutputExpected && outputAt != null &&
            SystemClock.elapsedRealtime() - outputAt < 2_000L
        ) {
            DjiLog.log("notice", "recovery", "decoder",
                "recovery: action=decoder effect=blocked reason=presentationOnly")
            if (coreWatchdog != 0L && DjiNative.isAvailable) DjiNative.feedWatchdogReset(coreWatchdog)
            feedWatchdog.reset()
            return
        }
        incidentSource?.noteExhausted(SystemClock.elapsedRealtime() / 1000.0)
        logRecovery(RecoveryAction.DECODER, RecoveryEffect.BLOCKED, RecoveryReason.PICTURE_DEADLINE)
        logRecovery(RecoveryAction.REJOIN, RecoveryEffect.REQUESTED, RecoveryReason.PICTURE_DEADLINE)
        rejoinDatalinkKeepingLive()
    }

    /** Keep the held picture; the fresh endpoint receives one enable from this repair owner. */
    private suspend fun rebuildDatalinkKeepingPicture(reason: String) {
        val link = datalink ?: return
        val source = incidentSource
        val owner = mediaPictureGeneration
        var startedAt = 0L
        repairDatalinkEndpoint(
            link = link,
            isCurrent = { datalink === it && !it.isClosed },
            ownsPicture = { ownsLivePicture(owner) },
            commandAdmission = endpointCommandAdmission,
            prepare = {
                _status.value = _status.value.copy(meteredEv = -1)
                retireEndpointCommands()
                liveViewEnableSends = 0
                resetFirstPictureFormatPoke()
                idrHoldEnableCount = 0
                firstPictureSettled = false
                focusTrackPending = true
                socketGeneration += 1
                source?.noteSocketGeneration(socketGeneration)
            },
            reopen = {
                decoder.prepareAfterForeground()
                decoder.flushForRecovery()
                it.rebuildUdp()
            },
            waitForPicture = {
                while (ownsLivePicture(owner) && datalink === link && !link.isClosed && !hasRecoveryPicture(startedAt)) {
                    recoverFirstPictureIfNeeded(SystemClock.elapsedRealtime(), link.videoPackets,
                        currentRepairOwnsPicture = true)
                    delay(100)
                }
            },
            recoverSession = {
                DjiLog.log("notice", "recovery", "endpoint",
                    "feed: endpoint repair did not restore picture ($reason)")
                if (!holdSessionRecoveryForLiveVideo()) {
                    beginSessionRecovery("camera endpoint did not recover", SessionRecoveryTrigger.DATALINK_LOST)
                }
            },
        ) {
            // Reject every queued pre-negotiation image, including one decoded
            // while open was awaiting its handshake. The next IDR owns picture.
            _status.value = _status.value.copy(meteredEv = -1)
            startedAt = decoder.beginPresentationProbe()
            sendCapturedLiveView(reason)
            if (coreWatchdog != 0L && DjiNative.isAvailable) DjiNative.feedWatchdogReset(coreWatchdog)
            feedWatchdog.reset()
        }
    }

    private fun retireEndpointCommands() {
        audioGeneration += 1
        audioTail?.cancel()
        audioTail = null
        failAllWaiters(kotlinx.coroutines.CancellationException("camera endpoint changed"))
        pairingHold.clear()
        inflight.clear()
        inflightPending.clear()
        commandTimeoutsAt.clear()
    }

    private fun startFeedRecovery(work: suspend () -> Unit) {
        if (isMultiviewBorrowed) return
        cancelProgrammedMove()
        val inFlight = datalink?.isRebuilding == true || feedRecoveryJob != null
        if (!LiveViewEnablePolicy.shouldStartFeedRecovery(inFlight)) return
        _status.value = _status.value.copy(meteredEv = -1)
        val job =
            scope.launch(start = CoroutineStart.LAZY) {
                try {
                    work()
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (e: Exception) {
                    Log.i(TAG, "feed: recovery work failed ${e.message}")
                } finally {
                    if (feedRecoveryJob === coroutineContext[Job]) feedRecoveryJob = null
                }
            }
        feedRecoveryJob = job
        job.start()
    }

    /** iOS `CameraSession.noteSceneBecameInactive`. */
    fun noteSceneBecameInactive() {
        // In the background Android blocks the camera network (sendto EPERM, Wi-Fi requests
        // unavailable at once), so recovery attempts there cannot reach the camera. Hold them.
        recoveryEpisode.pause()
        cancelProgrammedMove()
        endGimbalStick()
        if (_phase.value == ConnectionPhase.LIVE) needsForegroundRecover = true
        incidentSource?.recordBreadcrumb(
            FeedIncidentBreadcrumb(
                SystemClock.elapsedRealtime() / 1000.0,
                FeedIncidentBreadcrumbKind.SCENE_ACTIVITY,
                "inactive",
            ),
        )
        Log.i(TAG, "live: scene inactive — will recover feed on active")
    }

    /** Media return owns foreground picture recovery while its bounded task is pending. */
    fun noteSceneBecameActive() {
        recoveryEpisode.resume()
        if (isBrowsingMedia || mediaReturnPending) {
            needsForegroundRecover = false
            return
        }
        if (!needsForegroundRecover) return
        if (LiveViewEnablePolicy.shouldClearForegroundRecoverWithoutRebuild(holdsMonitor)) {
            needsForegroundRecover = false
            return
        }
        needsForegroundRecover = false
        if (_phase.value == ConnectionPhase.LIVE) {
            recoverAfterForeground()
            return
        }
        val id = connectedCamera?.id ?: reconnectTarget
        if (id != null) {
            Log.i(TAG, "live: scene active — session not live, reconnect")
            reconnect(id)
        }
    }

    /**
     * UDP and the present path die while suspended. Watchdog will not fire if
     * packets still arrive but the picture is frozen; that is the resume canvas.
     */
    private fun recoverAfterForeground() {
        if (!cameraNetworkUsable()) {
            DjiLog.log("notice", "recovery", "foreground-network",
                "live: foreground camera network unavailable — reconnect camera")
            releaseCameraPath()
            beginSessionRecovery("camera Wi-Fi changed while away", SessionRecoveryTrigger.SOFTAP_LOST)
            return
        }
        val returnedAt = decoder.beginPresentationProbe()
        val owner = mediaPictureGeneration
        val link = datalink
        endGimbalStick()
        startFeedRecovery {
            // Give an intact renderer a brief chance to deliver a new source image.
            delay(LiveViewEnablePolicy.STALL_MS)
            if (!ownsLivePicture(owner) || datalink !== link) return@startFeedRecovery
            if (hasRecoveryPicture(returnedAt)) return@startFeedRecovery
            if (!cameraNetworkUsable()) {
                releaseCameraPath()
                beginSessionRecovery("camera Wi-Fi changed while away", SessionRecoveryTrigger.SOFTAP_LOST)
                return@startFeedRecovery
            }
            DjiLog.log("notice", "recovery", "foreground-picture",
                "live: foreground picture did not return — reconnect camera")
            // A fresh session owns the next enable. Do not add a foreground PLI
            // alongside the watchdog while the old socket is still delivering.
            releaseCameraPath()
            beginSessionRecovery("picture did not return after app switch", SessionRecoveryTrigger.DATALINK_LOST)
        }
    }

    /**
     * Core `nextSessionHoldCycles`: a repair picture deadline with video still
     * arriving is a keyframe/decoder stall. Keep BLE; the watchdog owns it again.
     */
    private fun holdSessionRecoveryForLiveVideo(): Boolean {
        val now = SystemClock.elapsedRealtime()
        val videoAge = datalink?.lastVideoPacketAt?.let { now - it }
        val presented = decoder.lastPresentedAt
        val held = lastSessionHoldAt
        val pictureSinceLastHold = held != null && presented != null && presented > held
        sessionHoldCycles = LiveViewEnablePolicy.nextSessionHoldCycles(videoAge, sessionHoldCycles, pictureSinceLastHold)
        lastSessionHoldAt = now
        // Bounded: the maxHeldRepairCycles-th deadline in one episode releases to SessionRecovery.
        if (sessionHoldCycles == 0) return false
        DjiLog.log("notice", "recovery", "session",
            "feed: keep BLE, video still arriving; watchdog owns the stall cycle=$sessionHoldCycles")
        logRecovery(RecoveryAction.SESSION, RecoveryEffect.BLOCKED, RecoveryReason.VIDEO_LIVE)
        if (coreWatchdog != 0L && DjiNative.isAvailable) DjiNative.feedWatchdogReset(coreWatchdog)
        feedWatchdog.reset()
        return true
    }

    fun hasRecoveryPicture(startedAt: Long): Boolean =
        RecoveryPictureProof.isFresh(startedAt, SystemClock.elapsedRealtime(),
            decoder.lastPresentedAt, datalink?.lastAccessUnitAt)

    /** New UDP handshake on SoftAP. BLE and LIVE stay so the last frame is not dumped. */
    private suspend fun rejoinDatalinkKeepingLive() {
        val camera = connectedCamera ?: return
        val owner = mediaPictureGeneration
        if (!ownsLivePicture(owner)) return
        Log.i(TAG, "feed: full datalink rejoin (SoftAP bind kept)")
        retireEndpointCommands()
        disposeDatalink()
        withContext(Dispatchers.IO) { decoder.prepareAfterForeground() }
        liveViewEnableSends = 0
        resetFirstPictureFormatPoke()
        idrHoldEnableCount = 0
        firstPictureSettled = false
        focusTrackPending = true
        if (!cameraNetworkUsable()) {
            releaseCameraPath()
            beginSessionRecovery("camera Wi-Fi unavailable during rejoin", SessionRecoveryTrigger.SOFTAP_LOST)
            return
        }
        var negotiationCompleted = false
        try {
            openDatalinkKeepingLive(camera, warmRejoin = true, pictureOwner = owner)
            negotiationCompleted = true
            if (!ownsLivePicture(owner)) return
            val repairedLink = datalink
            val handshakeAt = SystemClock.elapsedRealtime()
            withTimeout(LiveViewEnablePolicy.ENDPOINT_PICTURE_GRACE_MS) {
                while (ownsLivePicture(owner) && datalink === repairedLink && !hasRecoveryPicture(handshakeAt)) delay(100)
            }
            if (!ownsLivePicture(owner) || datalink !== repairedLink) return
            // New session and new picture: the old stall ladder is over.
            if (coreWatchdog != 0L && DjiNative.isAvailable) DjiNative.feedWatchdogReset(coreWatchdog)
            feedWatchdog.reset()
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException && e !is TimeoutCancellationException) throw e
            if (negotiationCompleted && !ownsLivePicture(owner)) return
            if (e is TimeoutCancellationException && holdSessionRecoveryForLiveVideo()) return
            DjiLog.log("notice", "recovery", "session", "feed: full rejoin failed (${e.message})")
            disposeDatalink()
            // A null datalink under LIVE has no repair owner; bounded session
            // recovery (warm rehandshake, then BLE reconnect) takes it from here.
            beginSessionRecovery("datalink rejoin failed", SessionRecoveryTrigger.DATALINK_LOST)
        }
    }

    private fun sendCapturedLiveView(reason: String): Boolean {
        val repairEnable = reason.contains("watchdog")
        if (isBrowsingMedia && reason != "media browse ended") {
            if (repairEnable) {
                logRecovery(RecoveryAction.ENABLE, RecoveryEffect.BLOCKED, RecoveryReason.MEDIA)
            }
            return false
        }
        if (!liveEnableGate.begin()) {
            Log.i(TAG, "live: skip overlapping 0x09/0xa8 ($reason)")
            if (repairEnable) {
                logRecovery(RecoveryAction.ENABLE, RecoveryEffect.BLOCKED, RecoveryReason.SERIAL_GATE)
            }
            return false
        }
        try {
            val camera = connectedCamera
            val receiver = liveViewEnableReceiver(camera)
            // Handbook: do not send `0x02/0x0c` to start live view. Gallery leftover
            // is stray-playback's job. Unconditional exit sat on videoPkts=0.
            if (LiveViewEnablePolicy.shouldExitPlaybackBeforeLiveEnable(_status.value.inPlayback)) {
                datalink?.exitPlayback()
            }
            val nanoGate = usesNanoLiveViewGate(camera)
            if (nanoGate) datalink?.sendNanoGate(start = true)
            val prepare = camera?.model?.sendsLiveViewPrepare != false &&
                LiveViewEnablePolicy.shouldSendLiveViewPrepare(nanoGate)
            if (prepare) datalink?.sendCommand(DjiNative.CMD_TAP_FOCUS_HINT)
            datalink?.startLiveView(receiver)
            val now = SystemClock.elapsedRealtime()
            lastIdrRequest = now
            liveViewEnableSends += 1
            if (!decoder.awaitingIdr) idrHoldEnableCount = 0
            val presentedAge = decoder.lastPresentedAt?.let { now - it }
            if (LiveViewEnablePolicy.shouldBeginIDRHoldOnEnable(
                    hasPresentedPicture = presentedAge != null && presentedAge < LiveViewEnablePolicy.STALL_MS,
                )
            ) {
                decoder.beginIDRHold()
            }
            idrHoldEnableCount += 1
            Log.i(
                TAG,
                "live: ${if (prepare) "0x02/0x68 08 then " else ""}" +
                    "0x09/0xa8 rcv=0x${receiver.toString(16)} ($reason) #$liveViewEnableSends",
            )
            if (repairEnable) {
                logRecovery(RecoveryAction.ENABLE, RecoveryEffect.SENT, RecoveryReason.WATCHDOG)
            }
            return true
        } finally {
            liveEnableGate.end()
        }
    }

    private fun liveViewEnableReceiver(camera: FoundCamera?): Int {
        val model = camera?.model
        if (model != null && model.liveViewEnableReceiver != 0x08) return model.liveViewEnableReceiver
        if (model?.usesNanoLiveViewGate == true || model?.family == "nano") {
            return CameraCommands.LIVE_VIEW_ENABLE_RECEIVER_NANO
        }
        if (isNanoBody(camera)) return CameraCommands.LIVE_VIEW_ENABLE_RECEIVER_NANO
        return CameraCommands.LIVE_VIEW_ENABLE_RECEIVER_POCKET
    }

    private fun usesNanoLiveViewGate(camera: FoundCamera?): Boolean =
        camera?.model?.usesNanoLiveViewGate == true || isNanoBody(camera)

    private fun isNanoBody(camera: FoundCamera?): Boolean {
        if (camera == null) return false
        if (camera.modelId == 0x19) return true
        val n = camera.model.name.lowercase().replace(" ", "")
        return n.contains("nano") || n.contains("atto")
    }

    private fun failLink(reason: String) {
        when (_phase.value) {
            ConnectionPhase.IDLE, ConnectionPhase.SCANNING -> return
            ConnectionPhase.LIVE -> {
                beginSessionRecovery(reason)
                return
            }
            else -> Unit
        }
        if (holdsMonitor) {
            beginSessionRecovery(reason)
            return
        }
        Log.i(TAG, "link lost: $reason")
        _failure.value = reason
        _failureDetail.value = DjiFailures.linkLost(reason)
        _phase.value = ConnectionPhase.FAILED
        connectJob?.cancel()
        stopLivePipeline(preserveDecoder = false)
        ble.disconnect()
    }

    private fun leaveLiveForReconnect() {
        stopLivePipeline(preserveDecoder = false)
        ble.disconnect()
        _failure.value = null
        _failureDetail.value = null
        _phase.value = ConnectionPhase.FAILED
    }

    /** Drop the live UDP session so the next connect cannot inherit a half-closed driver. */
    private fun disposeDatalink() {
        cancelProgrammedMove()
        val link = datalink
        datalink = null
        _status.value = _status.value.copy(meteredEv = -1)
        if (link == null) return
        link.onAccessUnit = null
        link.onStatusFrame = null
        link.close()
    }

    private fun stopLivePipeline(preserveDecoder: Boolean, preserveSoftAP: Boolean = false) {
        keepaliveJob?.cancel()
        keepaliveJob = null
        endGimbalStick()
        retireEndpointCommands()
        disposeDatalink()
        if (preserveDecoder) decoder.flushForRecovery() else {
            decoder.reset()
            videoHistory.reset()
        }
        if (!preserveSoftAP) {
            releaseCameraPath()
        }
        videoPackets = 0
        accessUnits = 0
        framesEnqueued = 0
        droppedIncomplete = 0
        decoderErrors = 0
        hasVideoFormat = false
        streamStartedAt = null
        liveViewEnableSends = 0
        resetFirstPictureFormatPoke()
        idrHoldEnableCount = 0
        firstPictureSettled = false
        focusTrackPending = false
        lastFocusTrackAt = null
        lastCameraSetAt = null
        needsForegroundRecover = false
        feedWatchdog.reset()
        if (coreWatchdog != 0L && DjiNative.isAvailable) DjiNative.feedWatchdogReset(coreWatchdog)
    }

    fun retrySessionRecovery() {
        recoveryEpisode.resetStorm()
        cancelSessionRecovery(clearHoldsMonitor = false)
        beginSessionRecovery("operator retry", SessionRecoveryTrigger.OPERATOR_RETRY)
    }

    fun abandonRecoveryToMenu() {
        holdsMonitor = false
        disconnect()
    }

    /** The shared recovery episode; scan, BLE, Wi-Fi, datalink and decoder stay here. */
    private val recoveryEpisode by lazy {
        SessionRecoveryEpisode(
            scope = scope,
            port = RecoveryPort(),
            attemptDeadline = DJI_RECOVERY_ATTEMPT_DEADLINE,
            timing = SessionRecoveryEpisode.Timing(SystemClock::elapsedRealtime),
        ) { applyRecovery(it) }
    }

    private fun beginSessionRecovery(
        reason: String,
        trigger: SessionRecoveryTrigger = SessionRecoveryTrigger.BLE_DROPPED,
    ) {
        val camera = connectedCamera
        val cameraId = camera?.id ?: recoveryCameraId
        if (cameraId == null) {
            Log.i(TAG, "session: drop ($reason): no camera to recover")
            return
        }
        val previousTarget = recoveryCameraId
        recoveryCameraId = cameraId
        if (!recoveryEpisode.begin(cameraId, trigger, reason)) {
            if (!_recoveryState.value.isRecovering) recoveryCameraId = previousTarget
            return
        }
        if (recoveryDeviceName.isEmpty()) recoveryDeviceName = camera?.name.orEmpty()
        when (val state = _recoveryState.value) {
            is SessionRecoveryUi.PausedAfterDrops ->
                DjiLog.log("notice", "recovery", "session", "session: drop ($reason) → storm pause after ${state.drops} drops")
            else -> DjiLog.log("notice", "recovery", "session", "session: drop ($reason) → bounded recovery")
        }
    }

    private fun cancelSessionRecovery(clearHoldsMonitor: Boolean) {
        recoveryEpisode.cancel(clearHold = clearHoldsMonitor)
        if (clearHoldsMonitor) {
            holdsMonitor = false
            recoveryCameraId = null
            recoveryDeviceName = ""
        }
    }

    private fun applyRecovery(snapshot: SessionRecoveryEpisode.Snapshot) {
        val previous = _recoveryState.value
        _recoveryState.value = snapshot.state
        if (previous !is SessionRecoveryUi.Retrying) return
        when (val state = snapshot.state) {
            // A recovered episode keeps its target; a local cancel clears or keeps the hold.
            SessionRecoveryUi.Idle -> if (snapshot.targetId != null && !snapshot.holdsPicture) {
                holdsMonitor = false
                DjiLog.log("notice", "recovery", "session", "session: recovered after ${previous.attempt - 1} failed attempt(s)")
            }
            is SessionRecoveryUi.WaitingForOperator ->
                DjiLog.log("notice", "recovery", "budget", "session: recovery stopped after ${state.attemptsMade} attempt(s), operator retry required")
            else -> Unit
        }
    }

    /** The DJI transport for the shared episode. */
    private inner class RecoveryPort : SessionRecoveryEpisode.Port {
        // A lent session belongs to multiview; only its owner recovers it.
        override fun observe() =
            SessionRecoveryEpisode.Observation(
                ownsConnection = !isMultiviewBorrowed && recoveryCameraId != null,
                sourceAtMs = datalink?.lastAccessUnitAt,
                presentedAtMs = decoder.lastPresentedAt,
            )

        override fun cleanup(kind: SessionRecoveryEpisode.Cleanup, attempt: SessionRecoveryEpisode.Attempt) {
            when (kind) {
                SessionRecoveryEpisode.Cleanup.INITIAL_DROP -> {
                    SessionDropIncident.record(incidentSource, attempt.trigger, SystemClock.elapsedRealtime() / 1000.0)
                    holdsMonitor = true
                    feedRecoveryJob?.cancel()
                    feedRecoveryJob = null
                    connectJob?.cancel()
                    stopLivePipeline(preserveDecoder = true, preserveSoftAP = cameraPath.isProcessBound())
                    ble.disconnect()
                }
                SessionRecoveryEpisode.Cleanup.FAILED_ATTEMPT, SessionRecoveryEpisode.Cleanup.BUDGET_EXHAUSTED -> {
                    stopLivePipeline(preserveDecoder = true, preserveSoftAP = cameraNetworkUsable())
                    ble.disconnect()
                }
                SessionRecoveryEpisode.Cleanup.STORM_PAUSE -> Unit
            }
        }

        override suspend fun connect(attempt: SessionRecoveryEpisode.Attempt): Boolean {
            val id = recoveryCameraId ?: return false
            // Keep the held image and Surface, but retire a failed codec before the new session.
            withContext(Dispatchers.IO) { decoder.prepareAfterForeground() }
            attempt.checkContinuation()
            val found = withTimeoutOrNull(SessionRecoveryPolicy.ADVERTISEMENT_SCAN_BUDGET_MS) {
                ble.startScan()
                waitForRecoveryAdvertisement(id, SessionRecoveryPolicy.ADVERTISEMENT_SCAN_BUDGET_MS)
            } ?: return false
            attempt.checkContinuation()
            // BLE, pairing, Wi-Fi and the datalink handshake; a transport failure throws.
            run(found)
            return true
        }
    }

    private suspend fun waitForRecoveryAdvertisement(id: String, timeoutMs: Long): FoundCamera? {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            found.value.firstOrNull { it.id == id }?.let { return it }
            delay(250)
        }
        return null
    }

    private fun ingestDatalinkFrame(frame: DumlFrame) {
        // Pid 0x38 GET is untracked. Completing the shared 0x8E waiter here
        // stole Flip replies as audio/glamour ACKs after first picture.
        if (CameraCommands.isSelfieFlipGetReply(frame.cmdSet, frame.cmdId, frame.payload)) {
            lastSelfieFlipReplyElapsed = SystemClock.elapsedRealtime()
        } else {
            val waiter = waiters[frame.key]
            if (waiter != null) {
                waiter.keys.forEach { waiters.remove(it) }
                waiter.resume(frame)
            } else {
                val send = inflight[frame.key]
                if (send != null) {
                    finishInflight(send, frame)
                } else if (shouldHold(frame)) {
                    pairingHold[frame.key] = frame
                }
            }
        }
        val prev = _status.value
        val prevJson = statusJson?.takeIf { it.first === prev }?.second
            ?: prev.toJson().also { statusJson = prev to it }
        val json = DjiNative.applyStatus(frame.cmdSet, frame.cmdId, frame.payload, prevJson)
        var next = if (json != null) CameraStatus.fromJson(json) else prev
        if (json == null || !next.hasHudFields) next = next.preservingExtras(prev)
        next = next.carryingAperture(prev)
        val cam = connectedCamera?.model
        next = StatusExtras.apply(frame, next, cam?.name ?: "", cam?.family ?: "")
        val reported = StatusExtras.apply(frame, CameraStatus(), cam?.name ?: "", cam?.family ?: "")
        reportedCapture = StatusExtras.apply(
            frame, reportedCapture, cam?.name ?: "", cam?.family ?: "")
        if (StatusExtras.reportsShootingMode(frame)) {
            reportedCapture = reportedCapture.copy(shootingMode = next.shootingMode)
        }
        next = absorbStaleShootingMode(next, StatusExtras.reportsShootingMode(frame))
        next = next.mergingModeDependentCaps(prev)
        if (next.shootingMode != prev.shootingMode) {
            shootingModeRevision++
            formatPin = null
        }
        next = CamFov.absorb(next)
        // Reconcile the explicit Manual pin before accepting an Auto report.
        next = absorbStaleExpo(next, reported)
        reconcileAeLock(next)
        if (next.expoMode == CameraCommands.EXPO_AUTO && formatPin?.shutterAngle != null) {
            formatPin?.shutterAngle = null
            clearExpoPin(shutter = true)
        }
        val (formatStatus, angleRematch) =
            absorbStaleFormat(next, reported.resolutionCode >= 0 && reported.fpsIndex >= 0)
        next = formatStatus
        next = absorbStaleColor(next, reported)
        next = absorbStaleWhiteBalance(next, reported.wbMode >= 0 &&
            (reported.wbMode != CameraCommands.WB_CUSTOM || reported.wbKelvin >= 2000))
        reconcileAwbLock(next)
        next = absorbStaleFocus(next, reported.focusMode >= 0, reported.focusTrack >= 0)
        next = absorbStaleIsoLimit(next, reported.isoLimit >= 0)
        aperturePin?.let { pin ->
            val (held, remaining) = CameraValuePin.reconcile(
                pin, reported.apertureStrategy.takeIf { it >= 0 }, SystemClock.elapsedRealtime(),
            )
            aperturePin = remaining
            if (held != null) next = next.copy(apertureStrategy = held)
        }
        if (frame.cmdSet == 0x02 && frame.cmdId == 0xA0) {
            val (updated, blob) = StatusExtras.applyAudioDsp(frame.payload, next)
            next = updated
            if (blob != null) {
                audioDspBlob = blob
                next = next.applyingAudioBlob(blob)
            }
        }
        audioPin?.let { pin ->
            val (held, nextPin) =
                pin.absorb(
                    next,
                    _status.value,
                    SystemClock.elapsedRealtime(),
                    reportedValues = reported,
                )
            next = held
            audioPin = nextPin
        }
        noteReportedControlValues(frame, next, reported)
        if (isMultiviewControlOnly) {
            if (next != prev) { telemetryStatus = next; _status.value = next }
            rematchShutterAngle(angleRematch)
            controlSeam?.sessionDidChange()
            return
        }
        if (next.selfieFlip != prev.selfieFlip) {
            gimbalStickMapping = gimbalStickMapping.copy(selfieFlip = next.selfieFlip == true)
            syncGimbalPose()
        }
        if (frame.cmdSet == 0x04 && frame.cmdId == 0x05) {
            requestGimbalParams()
            if (frame.payload.size == 50 && next.gimbalModeFamily >= 0) {
                gimbalFollowFamilyConfirmed = next.gimbalModeFamily == 2
                val resolved = GimbalControl.modeFromFamily(next.gimbalModeFamily, _gimbalMode.value)
                val (held, pin) = CameraValuePin.reconcile(
                    gimbalModePin, if (gimbalFollowFamilyConfirmed) null else resolved,
                    SystemClock.elapsedRealtime(),
                )
                gimbalModePin = pin
                _gimbalMode.value = held ?: resolved
            }
            gimbalStickMapping = gimbalStickMapping.applyAttitude(frame.payload)
            levelReading.ingest(frame.payload, SystemClock.elapsedRealtimeNanos() / 1e9)
            judgeWorldLevelSnap()
            if (CameraCommands.isAttitude(frame.payload)) {
                val now = SystemClock.elapsedRealtime()
                val previousAt = lastValidGimbalAttitudeAt
                lastNativeGimbalPose = GimbalWaypoint.from(
                    CameraCommands.yawTenthDeg(frame.payload), CameraCommands.pitchTenthDeg(frame.payload),
                    _zoomReadout.value, CameraCommands.nativePitchTenthDeg(frame.payload))
                lastValidGimbalAttitudeAt = now
                val pose = liveGimbalWaypoint
                pose?.let { gimbalOverlayMotion.observe(it, now / 1000.0) }
                val anchor = captureStablePose
                if (gimbalStickHeld || moveDriving || now - gimbalRestedAt < 500 || pose == null) {
                    captureStableSince = 0L
                    captureStablePose = null
                } else if (anchor == null || now - previousAt > 300 ||
                    GimbalMoveEngine.angularDistance(anchor, pose) > GimbalMoveEngine.ARRIVE_DEG) {
                    // Keep this window's anchor fixed; small consecutive deltas can hide a slow drift.
                    captureStableSince = now
                    captureStablePose = pose
                }
                restoreGimbalPrep(gimbalPrep.restore(_gimbalMoveRunning.value, now / 1000.0))
            }
            syncGimbalPose()
            tickGimbalLimit()
        }
        if (frame.cmdSet == 0x04 && frame.cmdId == 0x27) {
            gimbalStickMapping = gimbalStickMapping.noteBodyFace(next.gimbalFace)
            syncGimbalPose()
        }
        noteZoomIfChanged(prev, next)
        if (frame.cmdSet == 0x02 && frame.cmdId == 0x89) {
            applyLiveTrackingPush(frame.payload)
        }
        if (frame.cmdSet == 0x02 && frame.cmdId == 0xA5) {
            applyTrackingPoll(frame.payload)
        }
        if (lastTapFocusAt != null) refreshTrackingHud()
        if (wasRecording && !next.isRecording) {
            cancelProgrammedMove()
        }
        wasRecording = next.isRecording
        if (frame.cmdSet == 0x04 && frame.cmdId == CameraCommands.CMD_GIMBAL_PARAMS &&
            StatusExtras.isGimbalParamsReply(frame.payload)) {
            if (next.gimbalTiltLock >= 0) {
                val current = _gimbalMode.value
                val resolved = GimbalControl.modeFromGet(next.gimbalTiltLock == 1, current)
                val confirmsTilt = gimbalFollowFamilyConfirmed &&
                    (current == GimbalMode.FOLLOW || current == GimbalMode.TILT_LOCKED)
                val (held, pin) = CameraValuePin.reconcile(
                    gimbalModePin, if (confirmsTilt) resolved else null, SystemClock.elapsedRealtime(),
                )
                gimbalModePin = pin
                _gimbalMode.value = held ?: resolved
            }
            GimbalSpeed.fromWire(next.gimbalSpeed)?.let { speed ->
                val (held, pin) = CameraValuePin.reconcile(gimbalSpeedPin, speed, SystemClock.elapsedRealtime())
                gimbalSpeedPin = pin
                _gimbalSpeed.value = held ?: speed
            }
        }
        if (next != prev) {
            if (next.inPlayback != prev.inPlayback) {
                Log.i(TAG, "live: inPlayback=${if (next.inPlayback) 1 else 0}")
            }
            telemetryStatus = next
            _status.value = next
            publishFaceDetectWanted()
        }
        rematchShutterAngle(angleRematch)
        confirmZoomColorHopIfReady()
        controlSeam?.sessionDidChange()
    }

    /** Only this frame's own decode counts: never a pin-held or optimistic value. */
    private fun noteReportedControlValues(frame: DumlFrame, decoded: CameraStatus, reported: CameraStatus) {
        noteReportedExposure(reported)
        // `0x02/0x80` carries the recording bit; the JNI decode of this frame is camera truth.
        if (frame.cmdSet == 0x02 && frame.cmdId == 0x80 && frame.payload.size >= 13) {
            reportedRecording = decoded.isRecording
        }
    }

    /** The ISO and white balance a report carries, as the control projection reads them. */
    private fun noteReportedExposure(reported: CameraStatus) {
        if (reported.isoIndex >= 0) reportedIsoIndex = reported.isoIndex
        if (reported.wbMode == CameraCommands.WB_AUTO) {
            reportedWhiteBalance = ReportedWhiteBalance(CameraCommands.WB_AUTO, 0, reported.wbTint)
        } else if (reported.wbMode == CameraCommands.WB_CUSTOM && reported.wbKelvin >= 2_000) {
            reportedWhiteBalance = ReportedWhiteBalance(CameraCommands.WB_CUSTOM, reported.wbKelvin, reported.wbTint)
        }
    }

    override fun controlState(): PocketControlState {
        val dl = datalink
        val status = _status.value
        return PocketControlState(
            linkReady = dl != null && endpointCommandAdmission.allows(dl.isClosed, dl.isRebuilding),
            authorized = controlLeaseAllows(),
            recovering = dl?.isRebuilding == true || recoveryEpisode.isRunning,
            phase = _phase.value,
            cameraId = connectedCamera?.id,
            shootingMode = status.shootingMode,
            busy = _controlBusy.value || isBrowsingMedia,
            isoChoices = CaptureWheels.isoIndices(status).filter { it != 0 || CaptureWheels.offersIsoAuto(status) },
            isoIndex = reportedIsoIndex,
            whiteBalance = reportedWhiteBalance,
            pendingWhiteBalance = whiteBalancePin?.let { ReportedWhiteBalance(it.wbMode, it.wbKelvin, it.wbTint) },
            recording = reportedRecording,
            batteryPercent = status.batteryPercent.takeIf { it in 0..100 },
            storage = djiStorageStatus(status),
            storageFreeMb = status.storageFreeMb.takeIf { status.storageTotalMb > 0 },
            storageTotalMb = status.storageTotalMb.takeIf { it > 0 },
            model = connectedCamera?.model,
            timecode = status.timecodeValue,
            audioLevels = DjiCameraSessionAdapter.audioLevels(status),
            charging = status.chargingReading,
        )
    }

    override fun captureControlState(): DjiCaptureControlState =
        DjiCaptureControlState(reportedCapture, connectedCamera?.model,
            if (appHost.shutterUsesAngle()) HostShutterPresentation.EMULATED_ANGLE else HostShutterPresentation.CAMERA_VALUE)

    override fun writeShutter(denominator: Int, onStage: (ControlWireEvent) -> Unit) {
        if (!captureControlState().admitsShutterWrite(denominator)) {
            onStage(ControlWireEvent.NOT_SENT)
            return
        }
        // Common duration edits never implicitly switch Auto into Manual.
        setShutterDenom(denominator, onStage, ensureManual = false)
    }

    override fun writeHostShutterAngle(degrees: Double, denominator: Int, admission: DjiCommandAdmission?, onStage: (ControlWireEvent) -> Unit) {
        if (!appHost.shutterUsesAngle() || reportedCapture.isPhoto || admission?.admits(commandOwner) == false) {
            onStage(ControlWireEvent.NOT_SENT)
            return
        }
        val source = commandOwner?.let { DjiCommandAdmission(it) { true } }
        val note: (ControlWireEvent) -> Unit = { stage ->
            if (stage == ControlWireEvent.SENT && source?.admits(commandOwner) == true && admission?.isCurrent != false) {
                appHost.setShutterAngleDegrees(degrees)
            }
            onStage(stage)
        }
        if (admission == null) writeShutter(denominator, note) else writeShutter(denominator, admission, note)
    }

    override fun writeExposureCompensation(value: EvComp, onStage: (ControlWireEvent) -> Unit) =
        setEv(value.thirds, onStage)

    override fun writeFocusMode(continuous: Boolean, onStage: (ControlWireEvent) -> Unit) =
        setFocusMode(continuous, onStage)

    override fun writeZoom(ratio: Double, onStage: (ControlWireEvent) -> Unit) =
        setZoom(ratio, onStage)

    override fun noteControlRejection(note: String) {
        _controlNote.value = note
    }

    /** Photo still. The rec lamp reaches this through `control.shutter()`. */
    override fun takePhoto() {
        _controlBusy.value = true
        fireKind(
            DjiNative.CMD_SHOOT_PHOTO,
            CaptureShutterPolicy.shootPhotoExtra(start = true),
            "Photo",
            retransmits = false,
            onSettle = { _controlBusy.value = false },
        )
    }

    /**
     * Explicit start or stop; callers go through `control`, which checks the reported state
     * first. Pocket 3 TimeLapse `0x02/0x01`; else video record `0x02/0x02`.
     */
    override fun setRecording(start: Boolean, onStage: ((ControlWireEvent) -> Unit)?) {
        val trigger =
            CaptureShutterPolicy.captureKind(_status.value.shootingMode, connectedCamera?.model?.name) ==
                CaptureShutterPolicy.CaptureKind.SHUTTER_TRIGGER
        _controlBusy.value = true
        fireKind(
            if (trigger) DjiNative.CMD_SHOOT_PHOTO else if (start) DjiNative.CMD_RECORD_START else DjiNative.CMD_RECORD_STOP,
            if (trigger) CaptureShutterPolicy.shootPhotoExtra(start = start) else null,
            if (trigger) (if (start) "TimeLapse" else "Stop") else if (start) "Record" else "Stop",
            onStage = onStage,
            expect = { reportedRecording == start },
            onSettle = { _controlBusy.value = false },
        )
    }

    fun setEv(thirds: Int) = setEv(thirds, null)

    private fun setEv(thirds: Int, onStage: ((ControlWireEvent) -> Unit)?) {
        val ev = EvComp.fromThirds(thirds)
        val previous = _status.value.evComp
        pinExpo(evComp = ev.rawValue)
        _status.value = _status.value.copy(evComp = ev.rawValue)
        fireKind(
            DjiNative.CMD_SET_EV,
            "${ev.rawValue}",
            "EV",
            coalesce = true,
            onStage = onStage,
            onFail = {
                if (_status.value.evComp == ev.rawValue) {
                    clearExpoPin(ev = true)
                    _status.value = _status.value.copy(evComp = previous)
                }
            },
        )
    }

    /** Snapshot EV on enable; restore it (or 0.0) on disable. Matches iOS. */
    fun setFacePriorityEnabled(on: Boolean) {
        if (on) {
            evBeforeFacePriority = EvComp.fromRaw(_status.value.evComp) ?: EvComp.ZERO
            publishFaceDetectWanted()
            return
        }
        val restore =
            FacePriorityExposure.restoreWrite(
                evBeforeFacePriority,
                expoIsAuto = _status.value.expoMode == CameraCommands.EXPO_AUTO,
                current = EvComp.fromRaw(_status.value.evComp),
            )
        evBeforeFacePriority = null
        lastFacePriorityEVAt = 0L
        facePriorityAcquireAt = null
        publishFaceDetectWanted()
        if (restore != null) setEv(restore.thirds)
    }

    fun setIsoLimit(raw: Int) {
        if (nativeISOCapabilities.ceiling != true) return
        val previous = _status.value.isoLimit
        isoLimitPin =
            IsoLimitPin(expected = raw, deadlineElapsedRealtime = SystemClock.elapsedRealtime() + 2_000L)
        val requestPin = isoLimitPin
        _status.value = _status.value.copy(isoLimit = raw)
        fireKind(
            DjiNative.CMD_SET_ISO_LIMIT,
            "$raw",
            "ISO limit",
            coalesce = true,
            onFail = {
                if (isoLimitPin === requestPin && _status.value.isoLimit == raw) {
                    isoLimitPin = null
                    _status.value = _status.value.copy(isoLimit = previous)
                }
            },
        )
    }

    /** Action 6 aperture strategy. Pinned until the camera reports it; a missed ACK leaves the HUD. */
    fun setApertureStrategy(raw: Int) {
        if (connectedCamera?.model?.supportsAperture != true) return
        val previous = _status.value.apertureStrategy
        val requestPin = CameraValuePin(raw, SystemClock.elapsedRealtime() + CameraValuePin.SETTLE_MS)
        aperturePin = requestPin
        _status.value = _status.value.copy(apertureStrategy = raw)
        fireKind(
            DjiNative.CMD_SET_APERTURE_STRATEGY,
            "$raw",
            "Aperture",
            coalesce = true,
            onFail = {
                if (aperturePin === requestPin && _status.value.apertureStrategy == raw) {
                    aperturePin = null
                    _status.value = _status.value.copy(apertureStrategy = previous)
                }
            },
        )
    }

    /** GET `0x8E` pid `0x000F`. Swift core already packs the bytes. */
    fun getIsoLimit() {
        if (_controlBusy.value) return
        scope.launch { refreshIsoLimit() }
    }

    /** GET only when Auto ISO exists. D-Log2 has no ceiling. */
    suspend fun refreshIsoLimit(): Boolean {
        if (nativeISOCapabilities.ceiling != true) return false
        if (!CameraCommands.shouldGetIsoLimit(_status.value.colorMode)) return false
        return sendKind(DjiNative.CMD_GET_ISO_LIMIT, null, "ISO limit GET")
    }

    /** True while a feed recover rebuild is in flight; FPS chip `RECOV`, not session recovery. */
    val isFeedRecovering: Boolean
        get() = feedRecoveryJob != null

    fun setShootingMode(raw: Int) {
        // Return the old mode to Auto before leaving it; the camera keeps Manual per mode.
        unlockAutoExposure()
        val previous = _status.value
        val revision = ++shootingModeRevision
        shootingModePin =
            ShootingModePin(
                expected = raw,
                deadlineElapsedRealtime = SystemClock.elapsedRealtime() + 2_000L,
            )
        val requestPin = shootingModePin
        _status.value =
            if (raw != previous.shootingMode) {
                formatPin = null
                previous.clearedModeDependentCapabilities().copy(shootingMode = raw)
            } else {
                previous.copy(shootingMode = raw)
            }
        fireKind(
            DjiNative.CMD_SET_SHOOTING_MODE,
            "$raw",
            "Mode",
            onFail = {
                if (shootingModeRevision != revision) return@fireKind
                if (shootingModePin === requestPin && _status.value.shootingMode == raw) {
                    shootingModeRevision++
                    formatPin = null
                    shootingModePin = null
                    _status.value = _status.value.copy(
                        shootingMode = previous.shootingMode,
                        availableVideoFormats = previous.availableVideoFormats,
                        availableShutterDenoms = previous.availableShutterDenoms,
                        availableIsoIndices = previous.availableIsoIndices,
                        availableColorModes = previous.availableColorModes,
                    )
                }
            },
        )
    }

    /** Unsnapped live / preview so 2.89× (shown 2.9×) still cycles to 3×. */
    fun zoomCycleFrom(): Double =
        zoomPinchPreview ?: zoomOptimistic ?: _status.value.zoomFactor ?: fallbackZoomStop()

    /** [zoomStop] can outlive the FORMAT that allowed it; see [CamFov.stopWithinCycle]. */
    private fun fallbackZoomStop(): Double = CamFov.stopWithinCycle(zoomStop, zoomStops())

    fun zoomStops(): List<Double> {
        val model = connectedCamera?.model ?: CameraModel.default
        return model.activeZoomStops(_status.value.resolutionCode, _status.value.shootingMode)
    }

    fun zoomMax(): Double = zoomStops().lastOrNull() ?: 1.0

    fun zoomNextJump(): Double = CamFov.nextJump(zoomCycleFrom(), zoomStops())

    fun setZoomLens(position: Int) {
        fireZoom(CameraCommands.zoomLens(position), announce = false, name = "Zoom slider")
    }

    fun setZoom(factor: Double) = setZoom(factor, null)

    private fun setZoom(factor: Double, onStage: ((ControlWireEvent) -> Unit)?) {
        if (!supportsZoom) {
            onStage?.invoke(ControlWireEvent.NOT_SENT)
            return
        }
        if (_gimbalMoveRunning.value) cancelProgrammedMove()
        val from = CamFov.displayLabel(_zoomReadout.value)
        val to = CamFov.displayLabel(factor)
        Log.i(TAG, "zoom: setZoom $from → $to live=${datalink != null}")
        val write = CamFov.chipWrite(factor)
        if (write == null) {
            _controlNote.value = "Zoom $to: no command"
            Log.i(TAG, "zoom: tap ignored — no write for $to")
            onStage?.invoke(ControlWireEvent.NOT_SENT)
            return
        }
        if (blockZoomColorHopIfRecording(factor)) {
            onStage?.invoke(ControlWireEvent.NOT_SENT)
            return
        }
        zoomPinchPreview = null
        dropDLog2ForZoom(factor)
        if (CamFov.holdZoomWrite(factor, _status.value.colorMode, zoomColorHopPending)) {
            queueZoomAfterHop(factor, onStage)
            return
        }
        zoomPin =
            CameraValuePin(factor, SystemClock.elapsedRealtime() + CameraValuePin.SETTLE_MS)
        markZoomStop(factor)
        val name = "Zoom $to"
        _controlNote.value = name
        when (write) {
            is CamFov.ChipWrite.Lens ->
                fireZoom(CameraCommands.zoomLens(write.position), announce = true, name = name, onStage = onStage)
            is CamFov.ChipWrite.Slew ->
                fireZoom(CameraCommands.zoomSlew(write.value), announce = true, name = name, onStage = onStage)
        }
        refreshZoomHud()
    }

    fun setZoomSlider(factor: Double) = setZoomSlider(factor, null)

    private fun setZoomSlider(factor: Double, onStage: ((ControlWireEvent) -> Unit)?) {
        if (_gimbalMoveRunning.value) cancelProgrammedMove()
        val position = CamFov.pinchLens(factor)
        val tenths = CamFov.displayTenths(factor)
        if (lastPinchLogTenths != tenths) {
            lastPinchLogTenths = tenths
            Log.i(TAG, "zoom: setZoomSlider ${CamFov.displayLabel(factor)} lens=$position")
        }
        if (blockZoomColorHopIfRecording(factor)) {
            onStage?.invoke(ControlWireEvent.NOT_SENT)
            return
        }
        dropDLog2ForZoom(factor)
        if (CamFov.holdZoomWrite(factor, _status.value.colorMode, zoomColorHopPending)) {
            queueZoomAfterHop(factor, onStage)
            return
        }
        fireZoom(CameraCommands.zoomLens(position), announce = false, name = "Zoom slider", onStage = onStage)
    }

    fun setZoomSlew(value: Int) {
        fireZoom(CameraCommands.zoomSlew(value), announce = false, name = "Zoom slew")
    }

    fun setZoomStop() {
        fireZoom(CameraCommands.zoomStop(), announce = false, name = "Zoom stop")
    }

    fun updateZoomPinch(magnification: Double) {
        if (!supportsZoom) return
        if (_gimbalMoveRunning.value) cancelProgrammedMove()
        if (zoomPinchPreview == null) {
            zoomPinchAnchor = _status.value.zoomFactor ?: zoomOptimistic ?: zoomStop
            zoomPin = null
            lastPinchLens = null
            lastPinchLogTenths = null
        }
        val factor = CamFov.pinchFactor(zoomPinchAnchor, magnification, zoomMax())
        if (blockZoomColorHopIfRecording(factor)) return
        val first = zoomPinchPreview == null
        dropDLog2ForZoom(factor)
        if (CamFov.holdZoomWrite(factor, _status.value.colorMode, zoomColorHopPending)) {
            queueZoomAfterHop(factor, null)
            zoomPinchPreview = factor
            refreshZoomHud()
            return
        }
        discardZoomAfterHop()
        zoomPinchPreview = factor
        val lens = CamFov.pinchLens(factor)
        refreshZoomHud()
        if (first && abs(factor - zoomPinchAnchor) < 0.01) return
        if (lastPinchLens == lens) return
        lastPinchLens = lens
        setZoomSlider(factor)
    }

    fun endZoomPinch() {
        discardZoomAfterHop()
        flushPendingZoom()
        val preview = zoomPinchPreview
        if (preview != null) {
            markZoomStop(preview)
            restoreDLog2IfNeeded(preview)
        }
        zoomPinchPreview = null
        lastPinchLens = null
        refreshZoomHud()
    }

    /** On-screen stick double-tap and gamepad Circle/B, per the Double-tap setting. */
    fun performGimbalDoubleTap() {
        when (gimbalDoubleTap) {
            GimbalDoubleTap.RECENTER -> recenterGimbal()
            GimbalDoubleTap.LEVEL -> levelGimbalToWorld()
        }
    }

    /**
     * Double-tap Level: one `0x04/0x14` move to the nearest world target (horizon
     * or plumb), judged on the attitude quaternion. Roll is not commanded.
     */
    fun levelGimbalToWorld() {
        val now = SystemClock.elapsedRealtimeNanos() / 1e9
        val tilt = levelReading.pitchDeg(now)
        if (tilt == null) {
            _controlNote.value = WorldLevelSnap.NO_LEVEL_DATA
            return
        }
        val link = datalink ?: return
        val pose = lastNativeGimbalPose
        val plan = pose?.let { WorldLevelSnap.plan(tilt, it, now) }
        if (plan == null) {
            _controlNote.value = WorldLevelSnap.UNREACHABLE_NOTE
            return
        }
        cancelProgrammedMove()
        captureStableSince = 0L
        captureStablePose = null
        gimbalRestedAt = SystemClock.elapsedRealtime()
        endGimbalStick()
        worldLevelSnap = plan.first
        link.sendDuml(
            cmdSet = 0x04,
            cmdId = CameraCommands.CMD_GIMBAL_ANGLE,
            payload = plan.second,
            flags = 0,
            receiver = CameraCommands.RX_GIMBAL,
        )
    }

    private fun judgeWorldLevelSnap() {
        val snap = worldLevelSnap ?: return
        // The operator or a programmed move took the gimbal: drop it silently.
        // A stick takeover also ends the camera's timed move so it cannot fight the stick.
        if (gimbalStickHeld || moveDriving) {
            worldLevelSnap = null
            if (gimbalStickHeld) sendTimedStop()
            return
        }
        val now = SystemClock.elapsedRealtimeNanos() / 1e9
        val fpv = if (_gimbalMode.value == GimbalMode.FPV) WorldLevelSnap.FPV_ROLL_NOTE else ""
        val note = when (val outcome = snap.evaluate(levelReading.pitchDeg(now), now)) {
            SnapOutcome.Pending -> return
            SnapOutcome.Expired -> null
            SnapOutcome.Arrived -> snap.target.successNote + fpv
            is SnapOutcome.Failed -> {
                sendTimedStop()
                WorldLevelSnap.failureNote(outcome.errorDeg) + fpv
            }
        }
        worldLevelSnap = null
        if (note != null) _controlNote.value = note
    }

    private fun sendTimedStop() {
        datalink?.sendDuml(
            cmdSet = 0x04,
            cmdId = CameraCommands.CMD_GIMBAL_ANGLE,
            payload = CameraCommands.gimbalTimedStop(),
            flags = 0,
            receiver = CameraCommands.RX_GIMBAL,
        )
    }

    fun recenterGimbal() {
        worldLevelSnap = null
        cancelProgrammedMove()
        captureStableSince = 0L
        captureStablePose = null
        gimbalRestedAt = SystemClock.elapsedRealtime()
        endGimbalStick()
        datalink?.sendDuml(
            cmdSet = 0x04,
            cmdId = CameraCommands.CMD_GIMBAL_MODE,
            payload = CameraCommands.gimbalRecenter(),
            receiver = CameraCommands.RX_GIMBAL,
        )
        _controlNote.value = "Gimbal re-centered"
    }

    fun flipGimbal() {
        cancelProgrammedMove()
        captureStableSince = 0L
        captureStablePose = null
        gimbalRestedAt = SystemClock.elapsedRealtime()
        endGimbalStick()
        gimbalStickMapping = gimbalStickMapping.noteRotate180()
        datalink?.sendDuml(
            cmdSet = 0x04,
            cmdId = CameraCommands.CMD_GIMBAL_MODE,
            payload = CameraCommands.gimbalFlip(),
            receiver = CameraCommands.RX_GIMBAL,
        )
    }

    val supportsTapFocus: Boolean
        get() = connectedCamera?.model?.supportsTapFocus ?: true

    val isTrackingActive: Boolean
        get() = isTracking || searchBox != null || subjectBox != null

    val isFocusResetAvailable: Boolean
        get() {
            val point = _focusPoint.value
            return FocusResetPolicy.isAvailable(
                point.first.toDouble(),
                point.second.toDouble(),
                isTrackingActive,
            )
        }

    private val feedDoubleTap = FeedDoubleTapTrack()

    /**
     * Feed tap: inside the AF-C face box → ActiveTrack with that rect. A second
     * tap on the same spot → ActiveTrack there (Mimo / on-camera). Else tap-focus.
     */
    fun handleFeedTap(x: Float, y: Float) {
        val nx = x.coerceIn(0f, 1f).toDouble()
        val ny = y.coerceIn(0f, 1f).toDouble()
        val hud = _trackingHud.value
        val box = FaceTrackTap.boxIfTapped(hud.overlay, nx, ny, hud.dimmedFaces)
        if (box != null) {
            feedDoubleTap.reset()
            startTracking(box)
            return
        }
        feedDoubleTap.register(nx, ny, SystemClock.elapsedRealtime() / 1000.0)?.let {
            startTracking(it)
            return
        }
        when (LiveFeedTapPolicy.action(supportsTapFocus, tappedFace = false)) {
            LiveFeedTapPolicy.Action.TAP_FOCUS -> markFocus(x, y)
            LiveFeedTapPolicy.Action.TRACK_FACE, LiveFeedTapPolicy.Action.IGNORE -> Unit
        }
    }

    fun startTracking(x: Float, y: Float, width: Float = 0.2f, height: Float = 0.2f) {
        startTracking(TrackingBox.fromCenter(x.toDouble(), y.toDouble(), width.toDouble(), height.toDouble()))
    }

    fun startTracking(box: TrackingBox) {
        cancelProgrammedMove()
        if (box.isTooSmall) {
            noteFrameTooSmall()
            return
        }
        stopTrackingPoll()
        lastOperatorClearAt = null
        lastLiveTrackingAt = null
        lastSubjectPushAt = null
        searchBox = box
        subjectBox = null
        trackingRequest = box
        trackingRequestAt = SystemClock.elapsedRealtime()
        isTracking = false
        trackingSawLock = false
        faceBox = null
        refreshTrackingHud()
        val id = nextTrackingId
        nextTrackingId = if (nextTrackingId == 0xFFFF) 1 else nextTrackingId + 1
        val extra =
            "$id\u001f${box.centerX}\u001f${box.centerY}\u001f${box.width}\u001f${box.height}"
        fireKind(
            DjiNative.CMD_SET_TRACKING_BOX,
            extra,
            "Track",
            onSettle = { ok -> if (ok) beginTrackingPoll() },
        )
    }

    fun cancelSubjectTracking() {
        cancelTracking(sendClear = true)
    }

    fun cancelTracking() {
        cancelTracking(sendClear = true)
    }

    fun presentControlNote(note: String) {
        _controlNote.value = note
    }

    fun handleGamepadAction(action: GamepadOperatorAction) {
        when (action) {
            GamepadOperatorAction.RECORD -> {
                if (_controlBusy.value) return
                control.shutter()
            }
            GamepadOperatorAction.RECENTER -> performGimbalDoubleTap()
            GamepadOperatorAction.FLIP -> flipGimbal()
            GamepadOperatorAction.TRACK -> handleGamepadTrackToggle()
            GamepadOperatorAction.ZOOM_CHIP_IN ->
                setZoom(CamFov.nextJump(zoomCycleFrom(), zoomStops()))
            GamepadOperatorAction.ZOOM_CHIP_OUT ->
                setZoom(CamFov.previousJump(zoomCycleFrom(), zoomStops()))
            GamepadOperatorAction.ISO_UP -> nudgeGamepadIso(1)
            GamepadOperatorAction.ISO_DOWN -> nudgeGamepadIso(-1)
            GamepadOperatorAction.SHUTTER_OPEN -> nudgeGamepadShutter(1)
            GamepadOperatorAction.SHUTTER_CLOSE -> nudgeGamepadShutter(-1)
        }
    }

    private fun nudgeGamepadIso(steps: Int) {
        val current = _status.value.isoIndex
        if (current < 0) return
        val available =
            _status.value.availableIsoIndices.ifEmpty { CameraCommands.ISO_INDEX_ALL }
        val next = CameraCommands.isoStepped(current, steps, available) ?: return
        setIsoIndex(next)
    }

    private fun nudgeGamepadShutter(steps: Int) {
        val status = _status.value
        val next =
            CameraCommands.shutterSteppedDenom(
                status.shutterDenom,
                steps,
                status.availableShutterDenoms,
            ) ?: return
        if (GamepadShutterSync.shouldPersistPreferredAngle(
                appHost.shutterUsesAngle(),
                CameraCommands.isPhotoMode(status.shootingMode),
                status.expoMode == CameraCommands.EXPO_AUTO,
            )
        ) {
            appHost.setShutterAngleDegrees(GamepadShutterSync.preferredAngle(next, status.fps))
        }
        setShutterDenom(next)
    }

    /** Triangle/Y: track the AF-C face in frame, or cancel if already tracking. */
    fun handleGamepadTrackToggle() {
        when (
            val action =
                GamepadFaceTrack.action(
                    isTrackingActive,
                    _trackingHud.value.overlay,
                    sceneFaces,
                )
        ) {
            GamepadFaceTrack.Action.Cancel -> cancelSubjectTracking()
            is GamepadFaceTrack.Action.Track -> startTracking(action.box)
            GamepadFaceTrack.Action.None -> Unit
        }
    }

    fun resetFocusPoint() {
        markFocus(0.5f, 0.5f)
    }

    fun applyDetectedFaces(faces: List<TrackingBox>) {
        if (!_wantsFaceDetect.value) {
            clearFaceAF()
            return
        }
        val now = SystemClock.elapsedRealtime()
        val dt = lastFaceAt?.let { (now - it) / 1000.0 } ?: 0.04
        lastFaceAt = now
        val moving = isFaceSceneMoving(now)
        sceneFaces = faces.take(SceneFacePolicy.MAX_FACES)
        if (isTrackingActive) {
            faceBox = null
            lastFaceHitAt = null
            refreshTrackingHud()
            return
        }
        if (!FaceAFPolicy.wantsFaceAF(_status.value.focusMode, _faceAFArmed.value)) {
            faceBox = null
            lastFaceHitAt = null
            refreshTrackingHud()
            return
        }
        val sinceHit = FaceTrackHold.secondsSinceHit(lastFaceHitAt, now)
        val hit =
            sceneFaces
                .filter {
                    FaceTrackHold.shouldAccept(
                        detected = it,
                        last = faceBox,
                        secondsSinceHit = sinceHit,
                        sceneMoving = moving,
                    )
                }
                .maxByOrNull { it.area }
        if (hit != null) {
            lastFaceHitAt = now
            faceBox =
                FaceTrackHold.follow(
                    faceBox,
                    hit,
                    dt.coerceIn(1.0 / 120.0, 0.08),
                    moving,
                )
        } else {
            tickFaceHold(now, moving)
        }
        refreshTrackingHud()
    }

    private fun isFaceSceneMoving(now: Long = SystemClock.elapsedRealtime()): Boolean =
        FaceTrackHold.isSceneMoving(lastGimbalStickAt?.let { (now - it) / 1000.0 })

    /** iOS `tickFaceBoxes`; drop the painted face after miss timeout. */
    private fun tickFaceHold(now: Long = SystemClock.elapsedRealtime(), moving: Boolean = isFaceSceneMoving(now)) {
        val sinceHit = FaceTrackHold.secondsSinceHit(lastFaceHitAt, now)
        if (!FaceTrackHold.shouldDrop(sinceHit, moving)) return
        if (faceBox == null && sceneFaces.isEmpty()) return
        faceBox = null
        sceneFaces = emptyList()
        lastFaceHitAt = null
        refreshTrackingHud()
    }

    /** iOS `decoder.onSourceFrame` → `considerFaceAF`. */
    /** False when the detector would drop a frame offered now; skip its readback. */
    fun wantsFaceFrame(): Boolean = faceDetector.wantsFrame()

    fun considerFaceFrame(frame: FaceFrame) {
        if (!_wantsFaceDetect.value) {
            frame.release()
            clearFaceAF()
            return
        }
        faceDetector.consider(frame) { hits -> applyDetectedFaces(hits) }
    }

    fun noteLiveFrame() {
        armFaceAFAfterFirstPicture()
    }

    private fun armFaceAFAfterFirstPicture() {
        if (_faceAFArmed.value || faceAFArmJob != null) return
        faceAFArmJob =
            scope.launch {
                while (isActive && !_faceAFArmed.value) {
                    delay(100)
                    if (decoder.lastPresentedAt != null) {
                        _faceAFArmed.value = true
                        publishFaceDetectWanted()
                    }
                }
                faceAFArmJob = null
            }
    }

    private fun publishFaceDetectWanted() {
        val live = _status.value
        val next =
            FaceAFPolicy.wantsFaceDetect(
                focusMode = live.focusMode,
                armed = _faceAFArmed.value,
                facePriority = evBeforeFacePriority != null,
                expoAuto = live.expoMode == CameraCommands.EXPO_AUTO,
            )
        if (_wantsFaceDetect.value == next) {
            if (next) ensureFaceTick()
            return
        }
        _wantsFaceDetect.value = next
        if (!next) {
            faceTickJob?.cancel()
            faceTickJob = null
            clearFaceAF()
        } else {
            ensureFaceTick()
        }
    }

    private fun ensureFaceTick() {
        if (faceTickJob != null) return
        faceTickJob =
            scope.launch {
                while (isActive && _wantsFaceDetect.value) {
                    delay(50)
                    tickFaceHold()
                }
                faceTickJob = null
            }
    }

    private fun clearFaceAF() {
        faceBox = null
        sceneFaces = emptyList()
        lastFaceAt = null
        lastFaceHitAt = null
        refreshTrackingHud()
    }

    fun markBrowsingMedia(browsing: Boolean, resumePending: Boolean = false): Long {
        mediaPictureGeneration += 1
        isBrowsingMedia = browsing
        mediaReturnPending = resumePending && !browsing
        mediaReturnSession.cancel()
        if (coreWatchdog != 0L && DjiNative.isAvailable) DjiNative.feedWatchdogReset(coreWatchdog)
        feedWatchdog.reset()
        return mediaPictureGeneration
    }

    /** Suspend the live-only Selfie Flip GET while playback/listing owns the camera. */
    fun setMediaTransportBrowsing(browsing: Boolean) {
        datalink?.setMediaBrowsing(browsing)
    }

    private fun ownsLivePicture(owner: Long): Boolean =
        MediaLiveResume.isCurrentPictureOwner(
            owner, mediaPictureGeneration, isBrowsingMedia)

    private fun ownsMediaReturnContext(owner: Long): Boolean =
        ownsLivePicture(owner) && _phase.value == ConnectionPhase.LIVE && !holdsMonitor && !recoveryEpisode.isRunning

    fun ownsMediaLiveResume(owner: Long): Boolean =
        ownsMediaReturnContext(owner) && datalink?.isClosed == false

    /** Let existing bounded negotiation finish, then borrow the one feed-repair slot. */
    suspend fun withMediaLiveResumeOwner(owner: Long, work: suspend () -> Unit) {
        try {
            if (!MediaLiveResumeRunner.awaitRepairSlot(
                    isCurrent = { ownsMediaReturnContext(owner) },
                    repairBusy = { feedRecoveryJob != null || datalink?.isRebuilding == true },
                )) return
            if (!ownsMediaLiveResume(owner)) {
                mediaLiveResumeExhausted(owner)
                return
            }
            kotlinx.coroutines.coroutineScope {
                val job = coroutineContext[Job] ?: return@coroutineScope
                feedRecoveryJob = job
                try { work() }
                finally { if (feedRecoveryJob === job) feedRecoveryJob = null }
            }
        } finally {
            if (owner == mediaPictureGeneration) mediaReturnPending = false
        }
    }

    fun mediaLiveResumeExhausted(owner: Long) {
        if (!ownsMediaReturnContext(owner)) return
        beginSessionRecovery("media return did not restore picture", SessionRecoveryTrigger.DATALINK_LOST)
    }

    /**
     * Settings / media cover the monitor. Do not drop pktType `0x02`;
     * live HEVC stays armed under the overlay (parity / #177).
     */
    fun setOperatorOverlayHeld(held: Boolean) {
        operatorOverlayHeld = held
    }

    /** iOS `restartLiveViewAfterMedia`: captured live-start, not a raw `0xa8`. */
    fun restartLiveViewAfterMedia(): Boolean {
        val link = datalink ?: return false
        if (isBrowsingMedia || link.isClosed || link.isRebuilding) return false
        _status.value = _status.value.copy(meteredEv = -1)
        return sendCapturedLiveView("media browse ended")
    }

    fun beginMediaBrowse() {
        markBrowsingMedia(true)
        // The camera owns playback: DJI Mimo sends no enter or listing here, and
        // ours put "Playback in progress" on the body. Closing still exits.
        if (_cameraGalleryOpen.value) {
            DjiLog.log("info", "media", "gallery", "media: opened for camera gallery — no enter playback")
            return
        }
        scope.launch {
            sendDumlWait(0x02, CameraCommands.CMD_PLAYBACK, CameraCommands.enterPlayback(), "Playback")
            listMedia()
        }
    }

    fun endMediaBrowse() {
        val owner = markBrowsingMedia(false, resumePending = true)
        val source = mediaConnectionIdentity
        mediaReturnSession.start(ifCurrent = {
            val currentSource = mediaConnectionIdentity
            ownsMediaReturnContext(owner) && if (source == null) currentSource == null
                else currentSource?.sameConnection(source) == true
        }, operation = {
            withMediaLiveResumeOwner(owner) {
                val startedAt = SystemClock.elapsedRealtime()
                val result = MediaLiveResumeRunner.run(
                    timeoutMs = LiveViewEnablePolicy.ENDPOINT_PICTURE_GRACE_MS,
                    nowMs = SystemClock::elapsedRealtime,
                    isCurrent = { ownsMediaLiveResume(owner) },
                    inPlayback = { _status.value.inPlayback },
                    pictureFresh = { hasRecoveryPicture(startedAt) },
                    exitPlayback = {
                        sendDumlWait(0x02, CameraCommands.CMD_PLAYBACK, CameraCommands.exitPlayback(), "Live")
                    },
                    enableLiveView = ::restartLiveViewAfterMedia,
                )
                if (result == MediaLiveResumeRunner.Result.EXHAUSTED) {
                    mediaLiveResumeExhausted(owner)
                }
            }
        })
    }

    fun listMedia() {
        datalink?.sendDuml(0x00, CameraCommands.CMD_MEDIA_LIST, CameraCommands.mediaListTrigger())
        datalink?.sendDuml(
            0x00,
            CameraCommands.CMD_MEDIA_LIST,
            CameraCommands.mediaList(counter = mediaListCounter, cursor = 1),
        )
        mediaListCounter = (mediaListCounter + 1) and 0xFF
        if (mediaListCounter == 0) mediaListCounter = 1
    }

    fun deleteMedia(handle: Int) {
        if (_controlBusy.value) return
        scope.launch {
            sendDumlWait(
                0x00,
                CameraCommands.CMD_MEDIA_DELETE,
                CameraCommands.deleteMedia(handle, mediaListCounter),
                "Delete",
            )
        }
    }

    fun setMediaFavorite(handle: Int, favorite: Boolean) {
        if (_controlBusy.value) return
        scope.launch {
            sendDumlWait(
                0x02,
                CameraCommands.CMD_MEDIA_FAVORITE,
                CameraCommands.setMediaFavorite(
                    handle, favorite, mediaListCounter, connectedCamera?.model?.name.orEmpty(),
                ),
                "Favorite",
            )
        }
    }

    override fun setIsoIndex(index: Int, onStage: ((ControlWireEvent) -> Unit)?) {
        val previous = _status.value.isoIndex
        pinExpo(isoIndex = index)
        _status.value = _status.value.copy(isoIndex = index)
        fireKind(
            DjiNative.CMD_SET_ISO_INDEX,
            "$index",
            "ISO",
            coalesce = true,
            onStage = onStage,
            expect = { reportedIsoIndex == index },
            onFail = {
                if (_status.value.isoIndex == index) {
                    clearExpoPin(iso = true)
                    _status.value = _status.value.copy(isoIndex = previous)
                }
            },
        )
    }

    fun setShutterDenom(denom: Int) = setShutterDenom(denom, null, ensureManual = true)

    private fun setShutterDenom(
        denom: Int, onStage: ((ControlWireEvent) -> Unit)?, ensureManual: Boolean,
    ) {
        formatPin?.shutterAngle = null
        if (ensureManual && _status.value.expoMode != CameraCommands.EXPO_MANUAL) {
            val previousExpo = _status.value.expoMode
            pinExpo(expoMode = CameraCommands.EXPO_MANUAL)
            _status.value = _status.value.copy(expoMode = CameraCommands.EXPO_MANUAL)
            fireKind(
                DjiNative.CMD_SET_EXPO_MODE,
                "manual",
                "Manual expo",
                onFail = {
                    if (_status.value.expoMode == CameraCommands.EXPO_MANUAL) {
                        clearExpoPin(mode = true)
                        _status.value = _status.value.copy(expoMode = previousExpo)
                    }
                },
            )
        }
        val previous = _status.value.shutterDenom
        pinExpo(shutterDenom = denom, expoMode = CameraCommands.EXPO_MANUAL)
        _status.value = _status.value.copy(shutterDenom = denom, expoMode = CameraCommands.EXPO_MANUAL)
        fireKind(
            DjiNative.CMD_SET_SHUTTER,
            "$denom",
            "1/$denom",
            coalesce = true,
            onStage = onStage,
            onFail = {
                if (_status.value.shutterDenom == denom) {
                    clearExpoPin(shutter = true)
                    _status.value = _status.value.copy(shutterDenom = previous)
                }
            },
        )
    }

    /** Only explicit angle choices write the saved intent; delayed telemetry never does. */
    fun setShutterAngle(degrees: Double) {
        val dl = datalink
        if (!controlLeaseAllows() || dl == null || !endpointCommandAdmission.allows(dl.isClosed, dl.isRebuilding)) {
            _controlNote.value = "not live"
            return
        }
        if (CameraCommands.isPhotoMode(_status.value.shootingMode)) return
        if (formatPin?.let { SystemClock.elapsedRealtime() >= it.activeDeadline } == true) formatPin = null
        val angle = ShutterAngle.nearestDegrees(degrees)
        appHost.setShutterAngleDegrees(angle)
        val current = _status.value
        val denom = ShutterAngle.denom(angle, current.fps, current.availableShutterDenoms)
        if (formatPin != null && current.expoMode == CameraCommands.EXPO_MANUAL &&
            !CameraCommands.isPhotoMode(current.shootingMode)) {
            formatPin?.shutterAngle = angle
            pinExpo(shutterDenom = denom)
            _status.value = current.copy(shutterDenom = denom)
            return
        }
        setShutterDenom(denom)
    }

    private fun rematchShutterAngle(degrees: Double?) {
        if (degrees == null || !appHost.shutterUsesAngle()) return
        val current = _status.value
        val dl = datalink
        if (current.expoMode != CameraCommands.EXPO_MANUAL || CameraCommands.isPhotoMode(current.shootingMode) ||
            !controlLeaseAllows() || dl == null || !endpointCommandAdmission.allows(dl.isClosed, dl.isRebuilding)) return
        val note = _controlNote.value
        setShutterDenom(ShutterAngle.denom(degrees, current.fps, current.availableShutterDenoms))
        if (_controlNote.value == null) _controlNote.value = note
    }

    fun setExpoMode(mode: Int) {
        val extra = CameraCommands.expoWireExtra(mode) ?: return
        // Manual from AE-L keeps the pinned values; the camera is already Manual.
        if (mode == CameraCommands.EXPO_MANUAL && _aeLock.value != null &&
            _status.value.expoMode == CameraCommands.EXPO_MANUAL) {
            _aeLock.value = null
            return
        }
        _aeLock.value = null
        if (mode != CameraCommands.EXPO_MANUAL) {
            formatPin?.shutterAngle = null
            clearExpoPin(shutter = true)
        }
        val previous = _status.value.expoMode
        pinExpo(expoMode = mode)
        _status.value = _status.value.copy(expoMode = mode)
        fireKind(
            DjiNative.CMD_SET_EXPO_MODE,
            extra,
            "ExpoMode",
            onFail = {
                if (_status.value.expoMode == mode) {
                    clearExpoPin(mode = true)
                    _status.value = _status.value.copy(expoMode = previous)
                }
            },
        )
    }

    private fun exposureLockDecision(kind: String, json: String): String? =
        if (DjiNative.isAvailable) DjiNative.exposureLockDecision(kind, json)?.takeIf { it.isNotEmpty() } else null

    val canLockAutoExposure: Boolean
        get() = _aeLock.value == null && exposureLockDecision("aeLock", _status.value.toJson()) != null

    /** Pins the applied Auto exposure as Manual (no captured native AE lock). iOS `lockAutoExposure`. */
    fun lockAutoExposure(): Boolean {
        val dl = datalink
        if (_aeLock.value != null || !controlLeaseAllows() || dl == null ||
            !endpointCommandAdmission.allows(dl.isClosed, dl.isRebuilding)) return false
        val lock = exposureLockDecision("aeLock", _status.value.toJson())
            ?.let { runCatching { JSONObject(it) }.getOrNull() }
            ?.let { AutoExposureLock(it.getInt("isoIndex"), it.getInt("shutterDenom"), it.getInt("shootingMode")) }
            ?: return false
        setExpoMode(CameraCommands.EXPO_MANUAL)
        setIsoIndex(lock.isoIndex)
        setShutterDenom(lock.shutterDenom)
        aeLockChecked = null
        _aeLock.value = lock
        Log.i(TAG, "ae-lock: ISO index ${lock.isoIndex} 1/${lock.shutterDenom}")
        return true
    }

    fun unlockAutoExposure() {
        if (_aeLock.value == null) return
        setExpoMode(CameraCommands.EXPO_AUTO)
    }

    /** Only (expo mode, shooting mode) decide `holds`, so ask the core when that pair moves. */
    private fun reconcileAeLock(status: CameraStatus) {
        val lock = _aeLock.value ?: return
        val key = status.expoMode to status.shootingMode
        if (key == aeLockChecked) return
        aeLockChecked = key
        val request = JSONObject(status.toJson()).put("lockShootingMode", lock.shootingMode)
        if (exposureLockDecision("aeLockHolds", request.toString()) == "false") _aeLock.value = null
    }

    /** `(kelvin, tint)` for AWB lock, or null unless Auto reports a live Kelvin. */
    fun autoWhiteBalanceLock(status: CameraStatus = _status.value): Pair<Int, Int>? =
        exposureLockDecision("awbLock", status.toJson())
            ?.let { runCatching { JSONObject(it) }.getOrNull() }
            ?.let { it.getInt("kelvin") to it.getInt("tint") }

    /**
     * Pins the live Auto Kelvin as Custom (no captured native AWB lock). iOS
     * `lockAutoWhiteBalance`: the optimistic Custom lands first, so the lock never sees a stale Auto.
     */
    fun lockAutoWhiteBalance() {
        if (_awbLockKelvin.value != null) return
        val (kelvin, tint) = autoWhiteBalanceLock() ?: return
        setWhiteBalance(kelvin, tint)
        val now = _status.value
        if (now.wbMode == CameraCommands.WB_CUSTOM && now.wbKelvin == kelvin) {
            awbLockChecked = null
            _awbLockKelvin.value = kelvin
        }
    }

    /** Only the reported (WB mode, Kelvin) decide `holds`, so ask the core when that pair moves. */
    private fun reconcileAwbLock(status: CameraStatus) {
        val kelvin = _awbLockKelvin.value ?: return
        val key = status.wbMode to status.wbKelvin
        if (key == awbLockChecked) return
        awbLockChecked = key
        val request = JSONObject(status.toJson()).put("lockKelvin", kelvin)
        if (exposureLockDecision("awbLockHolds", request.toString()) == "false") _awbLockKelvin.value = null
    }

    override fun setWhiteBalanceAuto(tint: Int?, onStage: ((ControlWireEvent) -> Unit)?) {
        _awbLockKelvin.value = null
        val previous = _status.value
        val next = (tint ?: _status.value.wbTint).coerceIn(-100, 100)
        whiteBalancePin =
            WhiteBalancePin(
                wbMode = CameraCommands.WB_AUTO,
                wbKelvin = _status.value.wbKelvin,
                wbTint = next,
                deadlineElapsedRealtime = SystemClock.elapsedRealtime() + 2_000L,
            )
        val requestPin = whiteBalancePin
        _status.value = _status.value.copy(wbMode = CameraCommands.WB_AUTO, wbTint = next)
        fireKind(
            DjiNative.CMD_SET_WB_AUTO,
            "$next",
            "WB Auto tint $next",
            coalesce = true,
            onStage = onStage,
            expect = { reportedWhiteBalance == ReportedWhiteBalance(CameraCommands.WB_AUTO, 0, next) },
            onFail = {
                if (whiteBalancePin === requestPin) {
                    whiteBalancePin = null
                    _status.value = _status.value.copy(
                        wbMode = previous.wbMode, wbKelvin = previous.wbKelvin, wbTint = previous.wbTint,
                    )
                }
            },
        )
    }

    override fun setWhiteBalance(kelvin: Int, tint: Int, onStage: ((ControlWireEvent) -> Unit)?) {
        val previous = _status.value
        val (k, t) = CameraCommands.clampWhiteBalanceCustom(kelvin, tint)
        // Custom from AWB Lock keeps the locked value; the camera is already there.
        if (_awbLockKelvin.value != null && previous.wbMode == CameraCommands.WB_CUSTOM &&
            previous.wbKelvin == k && previous.wbTint == t) {
            _awbLockKelvin.value = null
            onStage?.invoke(ControlWireEvent.CONFIRMED)
            return
        }
        _awbLockKelvin.value = null
        whiteBalancePin =
            WhiteBalancePin(
                wbMode = CameraCommands.WB_CUSTOM,
                wbKelvin = k,
                wbTint = t,
                deadlineElapsedRealtime = SystemClock.elapsedRealtime() + 2_000L,
            )
        val requestPin = whiteBalancePin
        _status.value = _status.value.copy(wbMode = CameraCommands.WB_CUSTOM, wbKelvin = k, wbTint = t)
        fireKind(
            DjiNative.CMD_SET_WB_CUSTOM,
            "$k\u001f$t",
            "WB ${k}K tint $t",
            coalesce = true,
            onStage = onStage,
            expect = { reportedWhiteBalance == ReportedWhiteBalance(CameraCommands.WB_CUSTOM, k, t) },
            onFail = {
                if (whiteBalancePin === requestPin) {
                    whiteBalancePin = null
                    _status.value = _status.value.copy(
                        wbMode = previous.wbMode, wbKelvin = previous.wbKelvin, wbTint = previous.wbTint,
                    )
                }
            },
        )
    }

    fun setFocusMode(continuous: Boolean) = setFocusMode(continuous, null)

    private fun setFocusMode(continuous: Boolean, onStage: ((ControlWireEvent) -> Unit)?) {
        if (!supportsFocusMode) {
            onStage?.invoke(ControlWireEvent.NOT_SENT)
            return
        }
        val next =
            if (continuous) CameraCommands.FOCUS_CONTINUOUS else CameraCommands.FOCUS_SINGLE
        val previous = _status.value.focusMode
        val now = SystemClock.elapsedRealtime()
        focusPin =
            FocusPin(
                focusMode = next,
                focusTrack = focusPin?.focusTrack,
                deadlineElapsedRealtime = now + 2_000L,
            )
        val requestPin = focusPin
        _status.value = _status.value.copy(focusMode = next)
        fireKind(
            DjiNative.CMD_SET_FOCUS_MODE,
            if (continuous) "2" else "1",
            "Focus",
            onStage = onStage,
            onFail = {
                if (focusPin?.requestId == requestPin?.requestId && focusPin?.focusMode != null && _status.value.focusMode == next) {
                    focusPin = focusPin?.copy(focusMode = null)?.takeIf { it.focusTrack != null }
                    _status.value = _status.value.copy(focusMode = previous)
                }
            },
        )
    }

    fun setFocusTrack(mode: Int) {
        if (!supportsFocusMode) return
        val track = FocusTrackMode.fromRaw(mode) ?: return
        val previous = _status.value.focusTrack
        val now = SystemClock.elapsedRealtime()
        lastFocusTrackAt = now
        focusPin =
            FocusPin(
                focusMode = focusPin?.focusMode,
                focusTrack = mode,
                deadlineElapsedRealtime = now + 2_000L,
            )
        val requestPin = focusPin
        _status.value = _status.value.copy(focusTrack = mode)
        fireKind(
            DjiNative.CMD_SET_FOCUS_TRACK,
            "$mode",
            "AF-C ${track.label}",
            onFail = {
                if (focusPin?.requestId == requestPin?.requestId && focusPin?.focusTrack != null && _status.value.focusTrack == mode) {
                    focusPin = focusPin?.copy(focusTrack = null)?.takeIf { it.focusMode != null }
                    _status.value = _status.value.copy(focusTrack = previous)
                }
            },
        )
    }

    fun refreshFocusTrack() {
        if (!supportsFocusMode) return
        if (_controlBusy.value) return
        scope.launch {
            sendKind(DjiNative.CMD_GET_FOCUS_TRACK, null, "Focus track GET")
        }
    }

    /**
     * `0x02/0x42` then optional native ISO hop; iOS `CameraSession.setColorMode`.
     * Optimistic HUD + pin until subscribe matches. Hop only when still on native
     * and [hopEnabled].
     */
    fun setColorMode(
        mode: Int,
        hopEnabled: Boolean = appHost.nativeISOHopEnabled(),
    ) {
        val live = _status.value
        val from = live.colorMode
        if (live.isRecording && mode != from) {
            _controlNote.value = ControlHud.RECORDING_COLOR_LOCK_NOTE
            return
        }
        val cam = connectedCamera?.model
        val family = cam?.family ?: "pocket"
        val allowed =
            CaptureWheels.colorWheel(family, live.availableColorModes, cam?.name ?: "")
                .map { it.first }
        if (mode !in allowed) return
        if (_gimbalMoveRunning.value) cancelProgrammedMove()
        if (mode == CameraCommands.COLOR_DLOG2) {
            teleColorSent = false
            zoomColorHopPending = false
            zoomColorHopUntilElapsed = 0L
            zoomColorHopGeneration += 1
        }
        pinColor(mode)
        fireKind(
            DjiNative.CMD_SET_COLOR_MODE,
            colorModeExtra(mode),
            CameraCommands.colorLabel(mode, family, connectedCamera?.model?.captureProfile?.labels ?: com.opencapture.opencine.vocabulary.CameraLabelProfile.standard),
            onFail = { colorPin = null },
        )
        hopNativeISO(from, mode, hopEnabled)
        if (mode == CameraCommands.COLOR_DLOG) confirmZoomColorHopIfReady()
    }

    /** JNI extra is the body SET byte; Pocket 3 / Nano is not `COLOR_*` raw. */
    private fun colorModeExtra(mode: Int): String {
        val cam = connectedCamera?.model
        return CameraCommands.wireColorMode(mode, cam?.name ?: "", cam?.family ?: "").toString()
    }

    /**
     * `0x02/0x18` via Swift `Commands.setVideoFormat`. Optimistic HUD, pin until
     * `cam_video_param_v2` matches, revert on ACK fail. Unlabeled res/fps do not SET.
     */
    fun setVideoFormat(format: VideoFormat, fromOperator: Boolean = true): Boolean {
        val previous = _status.value
        if (CameraCommands.isPhotoMode(previous.shootingMode)) return false
        if (fromOperator &&
            !VideoFormat.allowsOperatorSet(
                format, previous.availableVideoFormats, connectedCamera?.model, previous.shootingMode,
            )
        ) return false
        val modeAtSet = previous.shootingMode
        val rematch = ShutterAngle.formatRematch(
            degrees = formatPin?.shutterAngle ?: appHost.shutterAngleDegrees(),
            usesAngle = appHost.shutterUsesAngle(),
            manual = previous.expoMode == CameraCommands.EXPO_MANUAL,
            isPhoto = CameraCommands.isPhotoMode(previous.shootingMode),
            previousFps = previous.fps, nextFps = format.frameRate.fps,
            available = previous.availableShutterDenoms,
            alreadyPending = formatPin?.shutterAngle != null,
        )
        val angle = rematch?.degrees
        val shutter = rematch?.denom
        val pin =
            FormatPin(
                expected = format,
                deadlineElapsedRealtime = SystemClock.elapsedRealtime() + 2_000L,
                shutterAngle = angle,
            )
        formatPin = pin
        if (shutter != null) pinExpo(shutterDenom = shutter)
        _status.value =
            previous.copy(
                resolutionCode = format.resolution.rawValue,
                fpsIndex = format.frameRate.rawValue,
                fps = format.frameRate.fps,
                shutterDenom = shutter ?: previous.shutterDenom,
            )
        fireKind(
            DjiNative.CMD_SET_VIDEO_FORMAT,
            format.commandExtra(previous.shootingMode, connectedCamera?.model?.name),
            format.chipLabel,
            onFail = {
                if (formatPin !== pin) return@fireKind
                val live = _status.value
                if (CaptureShutterPolicy.canRevertFormatFailure(live.shootingMode, modeAtSet) &&
                    live.resolutionCode == format.resolution.rawValue &&
                    live.fpsIndex == format.frameRate.rawValue
                ) {
                    _status.value =
                        live.copy(
                            resolutionCode = previous.resolutionCode,
                            fpsIndex = previous.fpsIndex,
                            fps = previous.fps,
                            shutterDenom = if (pin.shutterAngle != null) previous.shutterDenom else live.shutterDenom,
                        )
                    if (pin.shutterAngle != null) clearExpoPin(shutter = true)
                }
                formatPin = null
            },
        )
        // Only actual format telemetry releases the shutter SET on the existing mailbox.
        if (_controlNote.value == null) {
            _controlNote.value =
                CamFov.ceilingNote(
                    format.resolution.sizeTitle,
                    zoomCycleFrom(),
                    connectedCamera
                        ?.model
                        ?.activeZoomStops(format.resolution.rawValue, modeAtSet)
                        .orEmpty(),
                )
        }
        return true
    }

    fun setResolutionFps(res: Int, fpsIndex: Int): Boolean {
        val format = VideoFormat.parse(res, fpsIndex) ?: return false
        return setVideoFormat(format)
    }

    private fun absorbStaleFormat(incoming: CameraStatus, formatReported: Boolean): Pair<CameraStatus, Double?> {
        val pending = formatPin
        val now = SystemClock.elapsedRealtime()
        val (next, remaining) =
            VideoFormat.absorbStale(
                incoming,
                formatPin,
                now,
                formatReported,
            )
        formatPin = remaining
        val angle = if (pending != null && remaining == null && formatReported &&
            now < pending.activeDeadline) pending.shutterAngle else null
        if (pending?.shutterAngle != null && now >= pending.activeDeadline) {
            _controlNote.value = "Frame rate unconfirmed; choose the shutter angle again"
        }
        return next to angle
    }

    private fun absorbStaleColor(incoming: CameraStatus, reported: CameraStatus): CameraStatus {
        val (next, remaining) =
            ColorPin.absorbStale(incoming, colorPin, SystemClock.elapsedRealtime(), reportedValues = reported)
        colorPin = remaining
        return next
    }

    private fun absorbStaleExpo(incoming: CameraStatus, reported: CameraStatus): CameraStatus {
        val now = SystemClock.elapsedRealtime()
        val pin = expoPin
        val (next, remaining) = pin?.absorb(incoming, _status.value, now, reportedValues = reported)
            ?: (incoming to null)
        expoPin = remaining
        val format = formatPin
        val angle = format?.shutterAngle
        // Exposure is a different stream of reports; even a matching shutter
        // cannot release the angle until the requested FORMAT itself is reported.
        return if (format != null && angle != null && now < format.activeDeadline &&
            next.expoMode == CameraCommands.EXPO_MANUAL) {
            next.copy(shutterDenom = ShutterAngle.denom(angle, format.expected.frameRate.fps, next.availableShutterDenoms))
        } else next
    }

    private fun absorbStaleShootingMode(incoming: CameraStatus, reported: Boolean): CameraStatus {
        val (next, remaining) =
            ShootingModePin.absorbStale(
                incoming, shootingModePin, SystemClock.elapsedRealtime(), reported,
            )
        shootingModePin = remaining
        return if (next.shootingMode != incoming.shootingMode) next.copy(
            availableVideoFormats = _status.value.availableVideoFormats,
            availableShutterDenoms = _status.value.availableShutterDenoms,
            availableIsoIndices = _status.value.availableIsoIndices,
            availableColorModes = _status.value.availableColorModes,
        ) else next
    }

    private fun absorbStaleWhiteBalance(incoming: CameraStatus, reported: Boolean): CameraStatus {
        val (next, remaining) =
            WhiteBalancePin.absorbStale(
                incoming, whiteBalancePin, SystemClock.elapsedRealtime(), reported,
            )
        whiteBalancePin = remaining
        return next
    }

    private fun absorbStaleFocus(
        incoming: CameraStatus,
        lensReported: Boolean,
        trackReported: Boolean,
    ): CameraStatus {
        val pin = focusPin ?: return incoming
        val (next, remaining) =
            pin.absorb(
                incoming,
                _status.value,
                SystemClock.elapsedRealtime(),
                lensReported,
                trackReported,
            )
        focusPin = remaining
        return next
    }

    private fun absorbStaleIsoLimit(incoming: CameraStatus, reported: Boolean): CameraStatus {
        val (next, remaining) =
            IsoLimitPin.absorbStale(incoming, isoLimitPin, SystemClock.elapsedRealtime(), reported)
        isoLimitPin = remaining
        return next
    }

    private fun pinExpo(
        isoIndex: Int? = null,
        shutterDenom: Int? = null,
        evComp: Int? = null,
        expoMode: Int? = null,
    ) {
        val now = SystemClock.elapsedRealtime()
        val pin = expoPin ?: ExpoPin(deadlineElapsedRealtime = now + 2_000L)
        expoPin =
            ExpoPin(
                isoIndex = isoIndex ?: pin.isoIndex,
                shutterDenom = shutterDenom ?: pin.shutterDenom,
                evComp = evComp ?: pin.evComp,
                expoMode = expoMode ?: pin.expoMode,
                deadlineElapsedRealtime = now + 2_000L,
            )
    }

    private fun clearExpoPin(
        iso: Boolean = false,
        shutter: Boolean = false,
        ev: Boolean = false,
        mode: Boolean = false,
    ) {
        val pin = expoPin ?: return
        val next =
            ExpoPin(
                isoIndex = if (iso) null else pin.isoIndex,
                shutterDenom = if (shutter) null else pin.shutterDenom,
                evComp = if (ev) null else pin.evComp,
                expoMode = if (mode) null else pin.expoMode,
                deadlineElapsedRealtime = pin.deadlineElapsedRealtime,
            )
        expoPin = if (next.isEmpty()) null else next
    }

    private fun pinColor(mode: Int) {
        _status.value = _status.value.copy(colorMode = mode)
        colorPin =
            ColorPin(
                expected = mode,
                deadlineElapsedRealtime = SystemClock.elapsedRealtime() + 2_000L,
            )
    }

    /** iOS `hopNativeISO`; fires immediately, does not wait for the color ACK. */
    private fun hopNativeISO(from: Int, to: Int, hopEnabled: Boolean) {
        if (nativeISOCapabilities.hop != true) return
        val hop =
            CameraCommands.nativeIsoHop(from, to, _status.value.isoIndex, hopEnabled) ?: return
        Log.i(
            TAG,
            "iso: native hop $from → $to ${_status.value.isoIndex} → $hop",
        )
        setIsoIndex(hop)
    }

    private fun blockZoomColorHopIfRecording(factor: Double): Boolean {
        if (
            !CamFov.zoomNeedsColorHopWhileRecording(
                factor,
                _status.value.colorMode,
                _status.value.isRecording,
            )
        ) {
            return false
        }
        _controlNote.value = ControlHud.RECORDING_COLOR_LOCK_NOTE
        Log.i(TAG, "zoom: blocked — color hop while recording")
        return true
    }

    private fun dropDLog2ForZoom(factor: Double) {
        if (blockZoomColorHopIfRecording(factor)) return
        val next = CamFov.colorModeForZoom(factor, _status.value.colorMode)
        if (next == null) {
            if (zoomPinchPreview == null && pendingZoomAfterHop == null && !zoomColorHopPending) {
                restoreDLog2IfNeeded(factor)
            }
            return
        }
        sendZoomColorOnce(next)
    }

    private fun sendZoomColorOnce(next: Int) {
        if (_status.value.isRecording) {
            _controlNote.value = ControlHud.RECORDING_COLOR_LOCK_NOTE
            return
        }
        val now = SystemClock.elapsedRealtime()
        if (zoomColorHopPending) {
            if (zoomColorHopUntilElapsed > 0L && now >= zoomColorHopUntilElapsed) {
                Log.i(TAG, "zoom: D-Log hop timed out — resend 0x42")
                zoomColorHopPending = false
                teleColorSent = false
            } else {
                return
            }
        }
        teleColorSent = true
        zoomColorHopPending = true
        zoomColorHopUntilElapsed = now + 2_000L
        zoomColorHopGeneration += 1
        val hopGen = zoomColorHopGeneration
        restoreDLog2OnWide = true
        val from = _status.value.colorMode
        // Do not pin color; holdZoomWrite must see live D-Log2 until the body hops.
        colorPin = null
        _controlNote.value = "D-Log (D-Log2 cannot zoom)"
        fireKind(
            DjiNative.CMD_SET_COLOR_MODE,
            colorModeExtra(next),
            "D-Log (zoom)",
            onFail = hopFail@{
                if (zoomColorHopGeneration != hopGen) return@hopFail
                colorPin = null
                restoreDLog2OnWide = false
                teleColorSent = false
                zoomColorHopPending = false
                zoomColorHopUntilElapsed = 0L
            },
            onSettle = hopSettle@{ ok ->
                Log.i(TAG, "zoom: D-Log2 → D-Log ack=${if (ok) "ok" else "failed"}")
                if (zoomColorHopGeneration != hopGen) return@hopSettle
                if (ok) {
                    confirmZoomColorHopIfReady()
                } else {
                    teleColorSent = false
                    zoomColorHopPending = false
                    zoomColorHopUntilElapsed = 0L
                }
            },
        )
        hopNativeISO(from, next, appHost.nativeISOHopEnabled())
        Log.i(TAG, "zoom: hold 0xB8 until D-Log2 → D-Log (from $from)")
    }

    private fun confirmZoomColorHopIfReady() {
        if (!zoomColorHopPending) return
        if (_status.value.colorMode != CameraCommands.COLOR_DLOG) return
        zoomColorHopPending = false
        zoomColorHopUntilElapsed = 0L
        pinColor(CameraCommands.COLOR_DLOG)
        Log.i(TAG, "zoom: D-Log2 → D-Log body confirmed")
        flushZoomAfterColorHop()
    }

    private fun flushZoomAfterColorHop() {
        val factor = pendingZoomAfterHop ?: return
        if (CamFov.holdZoomWrite(factor, _status.value.colorMode, zoomColorHopPending)) {
            return
        }
        val onStage = pendingZoomAfterHopStage
        pendingZoomAfterHop = null
        pendingZoomAfterHopStage = null
        zoomPinchPreview = factor
        markZoomStop(factor)
        refreshZoomHud()
        setZoomSlider(factor, onStage)
    }

    private fun queueZoomAfterHop(factor: Double, onStage: ((ControlWireEvent) -> Unit)?) {
        pendingZoomAfterHopStage?.invoke(ControlWireEvent.NOT_SENT)
        pendingZoomAfterHop = factor
        pendingZoomAfterHopStage = onStage
    }

    private fun discardZoomAfterHop() {
        val callback = pendingZoomAfterHopStage
        pendingZoomAfterHop = null
        pendingZoomAfterHopStage = null
        callback?.invoke(ControlWireEvent.NOT_SENT)
    }

    private fun restoreDLog2IfNeeded(factor: Double) {
        if (!restoreDLog2OnWide || !CamFov.shouldRestoreDLog2(factor)) return
        if (_status.value.isRecording) return
        restoreDLog2OnWide = false
        teleColorSent = false
        val from = _status.value.colorMode
        pinColor(CameraCommands.COLOR_DLOG2)
        fireKind(
            DjiNative.CMD_SET_COLOR_MODE,
            colorModeExtra(CameraCommands.COLOR_DLOG2),
            "D-Log2",
            onFail = { colorPin = null },
            onSettle = { ok -> if (ok) _controlNote.value = "Zoom 1× · D-Log2" },
        )
        hopNativeISO(from, CameraCommands.COLOR_DLOG2, appHost.nativeISOHopEnabled())
        Log.i(TAG, "zoom: restore D-Log2 on 1× (from $from)")
    }

    /** iOS `CameraSetMailbox.zoomCoalesceHold`; 20 Hz latest-wins slider. */
    private fun fireZoom(
        payload: ByteArray, announce: Boolean, name: String,
        onStage: ((ControlWireEvent) -> Unit)? = null,
    ) {
        if (!supportsZoom) {
            onStage?.invoke(ControlWireEvent.NOT_SENT)
            return
        }
        if (_gimbalMoveRunning.value) cancelProgrammedMove()
        val dl = datalink
        if (!controlLeaseAllows() || dl == null || !endpointCommandAdmission.allows(dl.isClosed, dl.isRebuilding)) {
            _controlNote.value = "Zoom not available"
            onStage?.invoke(ControlWireEvent.NOT_SENT)
            return
        }
        if (announce) {
            discardPendingZoom()
            zoomFlushJob?.cancel()
            zoomFlushJob = null
            dl.sendDuml(0x02, CameraCommands.CMD_ZOOM, payload)
            onStage?.invoke(ControlWireEvent.SENT)
            _controlNote.value = name
            lastZoomWireAt = SystemClock.elapsedRealtime()
            return
        }
        val now = SystemClock.elapsedRealtime()
        val wait = CamFov.SLIDER_COALESCE_MS - (now - lastZoomWireAt)
        if (wait <= 0L) {
            discardPendingZoom()
            zoomFlushJob?.cancel()
            zoomFlushJob = null
            lastZoomWireAt = now
            dl.sendDuml(0x02, CameraCommands.CMD_ZOOM, payload)
            onStage?.invoke(ControlWireEvent.SENT)
            return
        }
        discardPendingZoom()
        pendingZoomPayload = payload
        pendingZoomStage = onStage
        if (zoomFlushJob != null) return
        zoomFlushJob =
            scope.launch {
                delay(wait.coerceAtLeast(1L))
                val bytes = pendingZoomPayload
                val callback = pendingZoomStage
                pendingZoomPayload = null
                pendingZoomStage = null
                zoomFlushJob = null
                if (bytes != null) {
                    sendQueuedZoom(bytes, callback)
                }
            }
    }

    private fun flushPendingZoom() {
        zoomFlushJob?.cancel()
        zoomFlushJob = null
        val bytes = pendingZoomPayload ?: return
        val callback = pendingZoomStage
        pendingZoomPayload = null
        pendingZoomStage = null
        sendQueuedZoom(bytes, callback)
    }

    private fun sendQueuedZoom(bytes: ByteArray, onStage: ((ControlWireEvent) -> Unit)?) {
        val dl = datalink
        if (!controlLeaseAllows() || dl == null || !endpointCommandAdmission.allows(dl.isClosed, dl.isRebuilding)) {
            onStage?.invoke(ControlWireEvent.NOT_SENT)
            return
        }
        dl.sendDuml(0x02, CameraCommands.CMD_ZOOM, bytes)
        lastZoomWireAt = SystemClock.elapsedRealtime()
        onStage?.invoke(ControlWireEvent.SENT)
    }

    private fun discardPendingZoom() {
        val callback = pendingZoomStage
        pendingZoomPayload = null
        pendingZoomStage = null
        callback?.invoke(ControlWireEvent.NOT_SENT)
    }

    private fun markZoomStop(factor: Double) {
        zoomStop = factor
        zoomStopTouched = true
    }

    /**
     * [live] is a parameter so a status merge can hand over the frame it is folding in: the merge
     * publishes `_status` after this runs, and reading the old value there left the chip a frame
     * behind the camera.
     */
    private fun refreshZoomHud(live: Double? = _status.value.zoomFactor) {
        val fallback = fallbackZoomStop()
        _zoomDialReadout.value =
            CamFov.continuousReadout(
                live = live,
                preview = zoomPinchPreview,
                fallback = fallback,
                optimistic = zoomOptimistic,
            )
        _zoomReadout.value =
            CamFov.readout(
                live = live,
                preview = if (zoomColorHopPending) null else zoomPinchPreview,
                fallback = fallback,
                optimistic = if (zoomColorHopPending) null else zoomOptimistic,
            )
        _zoomPinching.value = zoomPinchPreview != null
    }

    private fun resetZoomHud() {
        zoomStop = 1.0
        zoomStopTouched = false
        zoomPinchPreview = null
        zoomPin = null
        zoomPinchAnchor = 1.0
        lastPinchLens = null
        lastPinchLogTenths = null
        refreshZoomHud()
    }

    /**
     * Drops a chip pin the camera never confirmed, so the HUD falls back to `cam_fov`. Returns true
     * when the pin went away and the HUD owes a redraw. [CamFov.matches] is the confirmation test
     * because the live factor comes back off a lens position, a hair off what was asked.
     */
    private fun reconcileZoomPin(live: Double?): Boolean {
        if (zoomPin == null) return false
        val (_, remaining) =
            CameraValuePin.reconcile(
                zoomPin, live, SystemClock.elapsedRealtime(), CamFov::matches,
            )
        zoomPin = remaining
        return remaining == null
    }

    private fun noteZoomIfChanged(prev: CameraStatus, incoming: CameraStatus) {
        // Before the early return: a body that clamps the ask, or that resets the
        // lens on its own, reports the same bytes every push and would never get
        // the pin cleared.
        val expired = reconcileZoomPin(incoming.zoomFactor)
        if (incoming.zoomFactorRaw == prev.zoomFactorRaw && incoming.zoomLens == prev.zoomLens) {
            if (expired) refreshZoomHud(incoming.zoomFactor)
            return
        }
        val factor = incoming.zoomFactor
        if (!zoomStopTouched && factor != null) {
            zoomStop =
                when {
                    abs(factor - CamFov.MAX_FACTOR) < 0.15 -> 12.0
                    abs(factor - 6) < 0.2 -> 6.0
                    abs(factor - 3) < 0.2 -> 3.0
                    factor < 2.5 -> 1.0
                    else -> zoomStop
                }
        }
        refreshZoomHud(incoming.zoomFactor)
    }

    fun setAudioChannel(value: Int) {
        pinAudio(channel = value)
        val previous = _status.value.audioChannel
        _status.value = _status.value.copy(audioChannel = value)
        val label = CameraCommands.audioChannelLabel(value) ?: value.toString()
        enqueueAudio {
            val ok = sendKind(DjiNative.CMD_SET_AUDIO_CHANNEL, "$value", "Audio $label")
            if (!ok) {
                if (_status.value.audioChannel == value) {
                    _status.value = _status.value.copy(audioChannel = previous)
                }
                clearAudioPin(channel = true)
            }
        }
    }

    fun setVocalBoost(on: Boolean) {
        val boost = if (on) 1 else 0
        pinAudio(vocal = boost)
        val previous = _status.value.vocalBoost
        _status.value = _status.value.copy(vocalBoost = boost)
        val label = if (on) "On" else "Off"
        enqueueAudio {
            val ok = sendKind(DjiNative.CMD_SET_VOCAL_BOOST, if (on) "1" else "0", "Vocal $label")
            if (!ok) {
                if (_status.value.vocalBoost == boost) {
                    _status.value = _status.value.copy(vocalBoost = previous)
                }
                clearAudioPin(vocal = true)
            }
        }
    }

    fun setWindNr(on: Boolean) {
        val value = if (on) 1 else 0
        pinAudio(wind = value)
        _status.value = _status.value.copy(windNr = value)
        enqueueAudio {
            patchAudioDsp("Wind ${if (on) "On" else "Off"}") { CameraCommands.patchWind(it, on) }
        }
    }

    fun setDirectionalAudio(mode: Int) {
        pinAudio(directional = mode)
        _status.value = _status.value.copy(directionalAudio = mode, windNr = 1)
        val label = CameraCommands.audioDirLabel(mode) ?: mode.toString()
        enqueueAudio {
            patchAudioDsp("Dir $label") { CameraCommands.patchDirectional(it, mode) }
        }
    }

    fun refreshAudio() {
        enqueueAudio {
            sendKind(DjiNative.CMD_GET_AUDIO_CHANNEL, null, "Audio ch GET")
            sendKind(DjiNative.CMD_GET_VOCAL_BOOST, null, "Vocal GET")
            sendKind(DjiNative.CMD_AUDIO_DSP_GET, null, "AudioDSP GET")
        }
    }

    fun updateGimbalStick(
        x: Float,
        y: Float,
        sensitivity: Int = CameraCommands.GIMBAL_STICK_DEFAULT_SENSITIVITY,
        assistMirror: Boolean = false,
        linear: Boolean = false,
        mapping: CameraCommands.VirtualJoystickMapping = CameraCommands.VirtualJoystickMapping.DEFAULT,
    ) {
        if ((_phase.value != ConnectionPhase.LIVE || needsForegroundRecover || holdsMonitor ||
                !firstPictureSettled || isLiveVideoStale()) && !moveDriving) {
            endGimbalStick()
            return
        }
        val restZone = if (linear) CameraCommands.GIMBAL_STICK_DEADZONE else mapping.deadzone
        if (_gimbalMoveRunning.value && !linear) {
            if (hypot(x.toDouble(), y.toDouble()) > restZone) {
                cancelProgrammedMove()
            } else {
                return
            }
        }
        var throwX = x
        var throwY = y
        if (!linear) {
            val last = lastGimbalStickAt
            val rawDt =
                if (last == null) 0.04
                else (SystemClock.elapsedRealtime() - last) / 1000.0
            val dt = rawDt.coerceIn(0.001, 0.12)
            val ramped = gimbalRampFilter.tick(x.toDouble(), y.toDouble(), gimbalRamp, dt)
            throwX = ramped.first.toFloat()
            throwY = ramped.second.toFloat()
        }
        lastAssistMirror = assistMirror
        lastGimbalStickAt = SystemClock.elapsedRealtime()
        lastGimbalCommand = throwX to throwY
        pendingGimbalAxes = encodedGimbalAxes(throwX, throwY, sensitivity, linear, mapping)
        val axes = pendingGimbalAxes
        if (axes.first == CameraCommands.GIMBAL_STICK_CENTER &&
            axes.second == CameraCommands.GIMBAL_STICK_CENTER
        ) {
            endGimbalStick()
            return
        }
        lastGimbalThrowAt = lastGimbalStickAt
        gimbalStickMapping = gimbalStickMapping.noteAppMotion()
        tickGimbalLimit()
        captureStableSince = 0L
        captureStablePose = null
        gimbalStickHeld = true
        datalink?.noteGimbalStick(axes.first, axes.second)
    }

    fun endGimbalStick() {
        if (moveDriving) return
        if (_gimbalMoveRunning.value) {
            cancelProgrammedMove()
            return
        }
        restGimbalStickWire()
    }

    private fun restGimbalStickWire() {
        gimbalRampFilter.reset()
        val wasHeld = gimbalStickHeld
        if (wasHeld) gimbalRestedAt = SystemClock.elapsedRealtime()
        gimbalStickHeld = false
        lastGimbalCommand = 0f to 0f
        gimbalLimitWatch.reset()
        pendingGimbalAxes =
            CameraCommands.GIMBAL_STICK_CENTER to CameraCommands.GIMBAL_STICK_CENTER
        if (wasHeld) datalink?.restGimbalStick()
    }

    fun setGimbalMode(mode: GimbalMode) {
        if (!canChangeGimbalSettings()) return
        cancelProgrammedMove()
        gimbalPrep.mode = null
        gimbalFollowFamilyConfirmed = false
        gimbalModePin = CameraValuePin(mode, SystemClock.elapsedRealtime() + 2_000L)
        _gimbalMode.value = mode
        when (mode) {
            GimbalMode.FOLLOW, GimbalMode.TILT_LOCKED -> {
                datalink?.sendDuml(
                    cmdSet = 0x04,
                    cmdId = CameraCommands.CMD_GIMBAL_MODE,
                    payload = CameraCommands.gimbalFollowFamily(),
                    receiver = CameraCommands.RX_GIMBAL,
                )
                datalink?.sendDuml(
                    cmdSet = 0x04,
                    cmdId = CameraCommands.CMD_GIMBAL_PARAMS,
                    payload = CameraCommands.setGimbalTiltLock(mode == GimbalMode.TILT_LOCKED),
                    receiver = CameraCommands.RX_GIMBAL,
                )
            }
            GimbalMode.FPV ->
                datalink?.sendDuml(
                    cmdSet = 0x04,
                    cmdId = CameraCommands.CMD_GIMBAL_MODE,
                    payload = CameraCommands.gimbalFpv(),
                    receiver = CameraCommands.RX_GIMBAL,
                )
            GimbalMode.DIRECTION_LOCK ->
                datalink?.sendDuml(
                    cmdSet = 0x04,
                    cmdId = CameraCommands.CMD_GIMBAL_MODE,
                    payload = CameraCommands.gimbalDirectionLock(),
                    receiver = CameraCommands.RX_GIMBAL,
                )
        }
    }

    fun setGimbalSpeed(speed: GimbalSpeed) {
        if (!canChangeGimbalSettings()) return
        cancelProgrammedMove()
        gimbalPrep.speed = null
        gimbalSpeedPin = CameraValuePin(speed, SystemClock.elapsedRealtime() + 2_000L)
        _gimbalSpeed.value = speed
        datalink?.sendDuml(
            cmdSet = 0x04,
            cmdId = CameraCommands.CMD_GIMBAL_PARAMS,
            payload = CameraCommands.setGimbalSpeed(speed.wire),
            receiver = CameraCommands.RX_GIMBAL,
        )
    }

    fun setGimbalWaypoint(slot: GimbalWaypointSlot) {
        val point = liveGimbalWaypoint
        if (point == null || gimbalTelemetryAge() > 0.3) {
            _controlNote.value = GimbalHudCopy.POSE_NOT_READY
            return
        }
        if (point != point.clamped()) {
            _controlNote.value = "Set the gimbal within its tilt limits"
            return
        }
        if (point.nativePitchDeg == null) {
            _controlNote.value = GimbalHudCopy.POSE_NOT_READY
            return
        }
        if (gimbalStickHeld || moveDriving || captureStableSince == 0L ||
            lastValidGimbalAttitudeAt - captureStableSince < 500) {
            _controlNote.value = GimbalHudCopy.HOLD_STILL
            return
        }
        _gimbalProgram.value = _gimbalProgram.value.withPoint(slot, point)
    }

    fun clearGimbalWaypoint(slot: GimbalWaypointSlot) {
        cancelProgrammedMove()
        _gimbalProgram.value = _gimbalProgram.value.withPoint(slot, null)
        if (!_gimbalProgram.value.canRun) cancelProgrammedMove()
    }

    fun setGimbalLegDuration(ab: Double? = null, bc: Double? = null) {
        cancelProgrammedMove()
        var next = _gimbalProgram.value
        if (ab != null) {
            val floor = GimbalProgram.minTravelDuration(next.a, next.b)
            next = next.copy(durationAB = GimbalProgram.snapDuration(maxOf(ab, floor)))
        }
        if (bc != null) {
            val floor = GimbalProgram.minTravelDuration(next.b, next.c)
            next = next.copy(durationBC = GimbalProgram.snapDuration(maxOf(bc, floor)))
        }
        _gimbalProgram.value = next
    }

    fun setGimbalSmoothness(value: Double) {
        if (!value.isFinite()) return
        cancelProgrammedMove()
        _gimbalProgram.value = _gimbalProgram.value.copy(smoothness = value.coerceIn(0.0, 1.0))
    }

    fun setGimbalLoop(enabled: Boolean) {
        cancelProgrammedMove()
        _gimbalProgram.value = _gimbalProgram.value.copy(loop = enabled)
    }

    fun clearGimbalProgram() {
        cancelProgrammedMove()
        val keep = _gimbalProgram.value
        _gimbalProgram.value = GimbalProgram(durationAB = keep.durationAB, durationBC = keep.durationBC)
    }

    fun runProgrammedMove() {
        if (!hasGimbal) return
        if (_gimbalMoveRunning.value) {
            cancelProgrammedMove()
            return
        }
        if (!firstPictureSettled || decoder.lastPresentedAt == null || isLiveVideoStale()) {
            _controlNote.value = "Wait for live video before running a move"
            return
        }
        val link = datalink ?: return
        val live = link.latestNativeProgramFeedback
        if (live == null || SystemClock.elapsedRealtimeNanos() / 1e9 - live.receivedAt !in 0.0..0.3) {
            _controlNote.value = GimbalHudCopy.POSE_NOT_READY
            return
        }
        val program = _gimbalProgram.value
        link.programmedZoomFailure(program)?.let {
            _controlNote.value = it
            return
        }
        if (live.pose.nativePitchDeg == null || listOfNotNull(program.a, program.b, program.c)
                .any { it.nativePitchDeg == null }) {
            _controlNote.value = "Set the gimbal points again"
            return
        }
        restGimbalStickWire()
        zoomFlushJob?.cancel()
        zoomFlushJob = null
        discardPendingZoom()
        discardZoomAfterHop()
        zoomColorHopGeneration += 1
        zoomColorHopPending = false
        restoreDLog2OnWide = false
        zoomPinchPreview = null
        refreshZoomHud()
        _gimbalMoveRunning.value = true
        _gimbalMovePaused.value = false
        moveDriving = true
        lastMoveHudAt = 0L
        lastMoveLogAt = 0L
        lastMoveReadout = null
        moveDatalink = link
        _gimbalMoveCountdown.value = 3
        moveCountdownJob = scope.launch {
            awaitMotionStartCountdown(pause = { delay(1_000) }) { _gimbalMoveCountdown.value = it }
            moveCountdownJob = null
            if (moveDatalink !== link || !_gimbalMoveRunning.value) return@launch
            if (!canRunProgrammedMove) {
                cancelProgrammedMove()
                _controlNote.value = link.programmedZoomFailure(program) ?: "Wait for live video before running a move"
                return@launch
            }
            prepProgrammedMoveGimbal()
            moveToken = link.startNativeProgram(program) { progress ->
                if (moveDatalink !== link || moveToken != progress.token) return@startNativeProgram
                _gimbalMovePaused.value = progress.paused
                progress.note?.let { _controlNote.value = it }
                lastMoveReadout = progress.readout
                publishMoveDebug(GimbalMoveEngine.formatDebug(progress.program, progress.live, progress.readout),
                    force = progress.finished)
                if (progress.finished) {
                    progress.failure?.let { _controlNote.value = it }
                    restGimbalStickWire()
                    gimbalRestedAt = SystemClock.elapsedRealtime()
                    _gimbalMoveRunning.value = false
                    _gimbalMovePaused.value = false
                    moveDriving = false
                    moveToken = null
                    moveDatalink = null
                }
            }
        }
    }

    fun pauseProgrammedMove() {
        if (_gimbalMovePaused.value || _gimbalMoveCountdown.value != null) return
        val token = moveToken ?: return
        if (moveDatalink?.pauseNativeProgram(token) == true) _gimbalMovePaused.value = true
    }

    fun resumeProgrammedMove() {
        if (!_gimbalMovePaused.value) return
        val token = moveToken ?: return
        moveDatalink?.resumeNativeProgram(token)
    }

    fun restartProgrammedMove() {
        if (!_gimbalMoveRunning.value || !_gimbalMovePaused.value) return
        cancelProgrammedMove()
        runProgrammedMove()
    }

    fun cancelProgrammedMove() {
        moveCountdownJob?.cancel()
        moveCountdownJob = null
        _gimbalMoveCountdown.value = null
        val token = moveToken
        val link = moveDatalink
        moveToken = null
        moveDatalink = null
        val was = _gimbalMoveRunning.value
        _gimbalMoveRunning.value = false
        _gimbalMovePaused.value = false
        moveDriving = false
        if (token != null) link?.cancelNativeProgram(token)
        if (was) {
            gimbalRestedAt = SystemClock.elapsedRealtime()
            restGimbalStickWire()
            lastMoveReadout = lastMoveReadout?.copy(phase = "STOP")
        }
        publishMoveDebug(gimbalDebugText(), force = true)
    }

    private fun gimbalTelemetryAge(nowMs: Long = SystemClock.elapsedRealtime()): Double =
        if (lastValidGimbalAttitudeAt == 0L) Double.POSITIVE_INFINITY else (nowMs - lastValidGimbalAttitudeAt) / 1000.0

    private fun prepProgrammedMoveGimbal() {
        gimbalPrep.prep(_gimbalSpeed.value, _gimbalMode.value).forEach { payload ->
            datalink?.sendDuml(
                cmdSet = 0x04,
                cmdId = CameraCommands.CMD_GIMBAL_PARAMS,
                payload = payload,
                receiver = CameraCommands.RX_GIMBAL,
            )
        }
        Log.i(TAG, "gimbal-move: Fast+unlock restore speed=${gimbalPrep.speed?.label} mode=${gimbalPrep.mode?.label}")
    }

    /** Put back the speed/tilt lock that [prepProgrammedMoveGimbal] replaced. */
    private fun restoreGimbalPrep(restore: GimbalPrepRestore.Restore?) {
        restore ?: return
        val link = datalink ?: return
        val deadline = SystemClock.elapsedRealtime() + 2_000L
        restore.speed?.let {
            gimbalSpeedPin = CameraValuePin(it, deadline)
            _gimbalSpeed.value = it
        }
        if (restore.mode == GimbalMode.TILT_LOCKED && _gimbalMode.value == GimbalMode.FOLLOW) {
            gimbalModePin = CameraValuePin(GimbalMode.TILT_LOCKED, deadline)
            _gimbalMode.value = GimbalMode.TILT_LOCKED
        }
        restore.payloads.forEach { payload ->
            link.sendDuml(
                cmdSet = 0x04,
                cmdId = CameraCommands.CMD_GIMBAL_PARAMS,
                payload = payload,
                receiver = CameraCommands.RX_GIMBAL,
            )
        }
        Log.i(TAG, "control: gimbal restore speed=${restore.speed?.label} mode=${restore.mode?.label}")
    }

    private fun publishMoveDebug(text: String, force: Boolean) {
        val now = SystemClock.elapsedRealtime()
        if (GimbalMoveEngine.DEBUG_HUD) {
            val hudDue = lastMoveHudAt == 0L || now - lastMoveHudAt >= 200L
            if (hudDue || force) {
                lastMoveHudAt = now
                _gimbalMoveReadout.value = text
            }
        } else if (_gimbalMoveReadout.value.isNotEmpty()) {
            _gimbalMoveReadout.value = ""
        }
        val logDue = lastMoveLogAt == 0L || now - lastMoveLogAt >= 500L
        if ((logDue || force) && text.isNotEmpty()) {
            lastMoveLogAt = now
            Log.i(TAG, "gimbal-move: ${text.replace("\n", " | ")}")
        }
    }

    private fun requestGimbalParams() {
        if (!hasGimbal || datalink == null ||
            !gimbalParamPoll.shouldRequest(SystemClock.elapsedRealtime())) return
        datalink?.sendDuml(
            cmdSet = 0x04,
            cmdId = CameraCommands.CMD_GIMBAL_PARAMS,
            payload = CameraCommands.gimbalParamsGet(),
            receiver = CameraCommands.RX_GIMBAL,
        )
    }

    private fun resetGimbalControls() {
        // Before the link closes: do not leave the camera on Fast for the next session.
        restoreGimbalPrep(gimbalPrep.restoreNow())
        cancelProgrammedMove()
        lastValidGimbalAttitudeAt = 0L
        lastNativeGimbalPose = null
        gimbalOverlayMotion.reset()
        captureStableSince = 0L
        captureStablePose = null
        gimbalRestedAt = 0L
        _gimbalProgram.value = GimbalProgram()
        _gimbalMode.value = GimbalMode.FOLLOW
        _gimbalSpeed.value = GimbalSpeed.DEFAULT
        gimbalParamPoll = GimbalParamPoll()
        gimbalRampFilter.reset()
        wasRecording = false
        _gimbalMoveReadout.value = ""
        lastMoveReadout = null
    }

    private fun isLiveVideoStale(): Boolean {
        val now = SystemClock.elapsedRealtime()
        val recovering = _phase.value != ConnectionPhase.LIVE || holdsMonitor ||
            feedRecoveryJob != null || datalink?.isRebuilding == true
        val videoAge = datalink?.lastVideoPacketAt?.let { now - it }
        val had = videoHistory.hadVideo(datalink?.videoPackets ?: 0, videoAge)
        return LiveViewEnablePolicy.shouldTreatLiveVideoAsStale(videoAge, had, recovering)
    }

    private fun canChangeGimbalSettings(): Boolean = acceptsGimbalConfiguration(
        hasGimbal = hasGimbal,
        live = _phase.value == ConnectionPhase.LIVE,
        sceneActive = !needsForegroundRecover && !isBrowsingMedia,
        warming = !firstPictureSettled || decoder.lastPresentedAt?.let {
            SystemClock.elapsedRealtime() - it in 0 until LiveViewEnablePolicy.STALL_MS
        } != true,
        recovering = holdsMonitor || recoveryEpisode.isRunning || feedRecoveryJob != null,
        videoStale = isLiveVideoStale(),
        hasDatalink = datalink?.isClosed == false,
    )

    /** Prefer the Swift `GimbalStick.encode` wire; Kotlin copies the same gain/deadzone. */
    private fun encodedGimbalAxes(
        x: Float,
        y: Float,
        sensitivity: Int,
        linear: Boolean = false,
        mapping: CameraCommands.VirtualJoystickMapping = CameraCommands.VirtualJoystickMapping.DEFAULT,
    ): Pair<Int, Int> {
        val invertPan =
            if (linear) false
            else CameraCommands.liveInvertPan(gimbalStickMapping.invertPan, lastAssistMirror)
        val applied = if (linear) CameraCommands.VirtualJoystickMapping.DEFAULT else mapping
        if (applied.isDefault && !linear && DjiNative.isAvailable) {
            val packed =
                DjiNative.gimbalStickEncode(x.toDouble(), y.toDouble(), invertPan, sensitivity)
            if (packed != null) {
                val parts = packed.split(',')
                if (parts.size == 2) {
                    val axis0 = parts[0].toIntOrNull()
                    val axis1 = parts[1].toIntOrNull()
                    if (axis0 != null && axis1 != null) return axis0 to axis1
                }
            }
        }
        return CameraCommands.gimbalAxes(
            x,
            y,
            invertPan = invertPan,
            sensitivity = sensitivity,
            mapping = applied,
            linear = linear,
        )
    }

    private fun syncGimbalPose() {
        _gimbalPoseViewFlip.value = gimbalStickMapping.poseViewFlip
        _gimbalPoseInvertPan.value = gimbalStickMapping.invertPan
    }

    private fun tickGimbalLimit() {
        val pulse =
            gimbalLimitWatch.tick(
                x = lastGimbalCommand.first.toDouble(),
                y = lastGimbalCommand.second.toDouble(),
                yawTenthDeg = gimbalStickMapping.yawTenthDeg,
                pitchTenthDeg = gimbalStickMapping.pitchTenthDeg,
                now = SystemClock.elapsedRealtime() / 1000.0,
                settling180 = gimbalStickMapping.pendingWant180.isNotEmpty(),
            )
        if (pulse.isEmpty) return
        lastGimbalLimitContact = pulse
        lastGimbalLimitPanSign = gimbalLimitWatch.lastPanSign
        lastGimbalLimitTiltSign = gimbalLimitWatch.lastTiltSign
        _gimbalLimitPulse.value = _gimbalLimitPulse.value + 1
    }

    fun tapFocus(x: Float, y: Float) {
        markFocus(x, y)
    }

    private fun markFocus(x: Float, y: Float) {
        if (!supportsTapFocus) return
        cancelTracking(sendClear = isTrackingActive)
        lastTapFocusAt = SystemClock.elapsedRealtime()
        faceBox = null
        val nx = x.coerceIn(0f, 1f)
        val ny = y.coerceIn(0f, 1f)
        _focusPoint.value = nx to ny
        refreshTrackingHud()
        val dl = datalink ?: return
        dl.sendDuml(0x02, 0x22, byteArrayOf(0x02))
        val xy = "$nx\u001f$ny"
        scope.launch {
            val focused =
                sendKind(DjiNative.CMD_TAP_FOCUS_POINT, xy, "Focus region", timeoutMs = 800)
            if (!focused) return@launch
            sendKind(DjiNative.CMD_TAP_FOCUS_HINT, null, "AE hint", timeoutMs = 800)
            sendKind(DjiNative.CMD_TAP_FOCUS_COMMIT, xy, "Focus", timeoutMs = 800)
        }
    }

    private fun noteFrameTooSmall() {
        searchBox = null
        subjectBox = null
        isTracking = false
        refreshTrackingHud()
        _controlNote.value = "Frame Too Small"
        scope.launch {
            delay(2_000)
            if (_controlNote.value == "Frame Too Small") _controlNote.value = null
        }
    }

    private fun cancelTracking(sendClear: Boolean) {
        val had = isTrackingActive
        stopTrackingPoll()
        searchBox = null
        subjectBox = null
        isTracking = false
        trackingSawLock = false
        if (sendClear) lastOperatorClearAt = SystemClock.elapsedRealtime()
        lastLiveTrackingAt = null
        lastSubjectPushAt = null
        trackingRequest = null
        refreshTrackingHud()
        if (!sendClear || !had || datalink == null) return
        fireKind(DjiNative.CMD_CLEAR_TRACKING_BOX, null, "Track clear")
    }

    private fun beginTrackingPoll() {
        stopTrackingPoll()
        trackingPollJob =
            scope.launch {
                var idleTicks = 0
                while (isActive && isTrackingActive) {
                    datalink?.sendDuml(0x02, CameraCommands.CMD_TRACK_POLL, CameraCommands.pollTracking())
                    delay(500)
                    val now = SystemClock.elapsedRealtime()
                    if (trackingSawLock &&
                        TrackingClearPolicy.shouldDropForSilence(lastSubjectPushAt, now)
                    ) {
                        clearLocalTracking()
                        return@launch
                    }
                    if (isTracking) {
                        idleTicks = 0
                    } else if (trackingSawLock) {
                        clearLocalTracking()
                        return@launch
                    } else {
                        idleTicks += 1
                        if (idleTicks >= 6) {
                            clearLocalTracking()
                            return@launch
                        }
                    }
                }
            }
    }

    private fun stopTrackingPoll() {
        trackingPollJob?.cancel()
        trackingPollJob = null
    }

    private fun clearLocalTracking() {
        searchBox = null
        subjectBox = null
        isTracking = false
        lastLiveTrackingAt = null
        lastSubjectPushAt = null
        stopTrackingPoll()
        refreshTrackingHud()
    }

    /** Drop the camera's previous subject until it reports the operator's new box. */
    private fun acceptsTrackingReport(box: TrackingBox, now: Long): Boolean {
        val requested = trackingRequest ?: return true
        val since = trackingRequestAt?.let { (now - it) / 1000.0 }
        if (!TrackingStartPolicy.accepts(box, requested, since)) return false
        trackingRequest = null
        return true
    }

    private fun applyLiveTrackingPush(payload: ByteArray) {
        val now = SystemClock.elapsedRealtime()
        if (!TrackingClearPolicy.shouldApplyLivePush(lastOperatorClearAt, now)) return
        val box = TrackingBox.parseLivePush(payload) ?: return
        if (!acceptsTrackingReport(box, now)) return
        lastSubjectPushAt = now
        subjectBox = smoothedSubject(box)
        isTracking = true
        trackingSawLock = true
        searchBox = null
        adoptCameraFocus(box.centerX, box.centerY, fromTrackingBox = true)
        refreshTrackingHud()
        if (trackingPollJob == null) beginTrackingPoll()
    }

    private fun applyTrackingPoll(payload: ByteArray) {
        val now = SystemClock.elapsedRealtime()
        if (!TrackingClearPolicy.shouldApplyLivePush(lastOperatorClearAt, now)) return
        when (val poll = TrackingPoll.parse(payload)) {
            is TrackingPoll.Locked -> {
                if (poll.box?.let { acceptsTrackingReport(it, now) } == false) return
                isTracking = true
                trackingSawLock = true
                val cameraBox = poll.box
                if (cameraBox != null) {
                    subjectBox = smoothedSubject(cameraBox)
                } else if (subjectBox == null) {
                    searchBox?.let { subjectBox = TrackingBox.subject(it) }
                }
                searchBox = null
                refreshTrackingHud()
            }
            TrackingPoll.Idle -> {
                isTracking = false
                if (trackingSawLock) clearLocalTracking()
                else refreshTrackingHud()
            }
            null -> Unit
        }
    }

    private fun smoothedSubject(toward: TrackingBox): TrackingBox {
        val now = SystemClock.elapsedRealtime()
        val dt = lastLiveTrackingAt?.let { (now - it) / 1000.0 } ?: Double.POSITIVE_INFINITY
        lastLiveTrackingAt = now
        return TrackingBoxSmoothing.blend(subjectBox, toward, dt)
    }

    private fun adoptCameraFocus(x: Double, y: Double, fromTrackingBox: Boolean) {
        val cur = _focusPoint.value
        if (!CameraFocusPolicy.shouldAdopt(cur.first.toDouble(), cur.second.toDouble(), x, y)) return
        _focusPoint.value = x.toFloat() to y.toFloat()
        if (fromTrackingBox) return
        lastTapFocusAt = SystemClock.elapsedRealtime()
        faceBox = null
    }

    private fun refreshTrackingHud() {
        val now = SystemClock.elapsedRealtime()
        val sinceTap = lastTapFocusAt?.let { (now - it) / 1000.0 }
        val overlay =
            if (FaceAFPolicy.shouldHoldTapBox(sinceTap)) {
                val base = FocusOverlayPolicy.resolve(isTracking, searchBox, subjectBox)
                when (base) {
                    is FocusOverlay.Search, is FocusOverlay.Subject -> base
                    is FocusOverlay.Focus, is FocusOverlay.Face -> FocusOverlay.Focus
                }
            } else {
                FaceAFPolicy.resolve(
                    _status.value.focusMode,
                    isTracking,
                    searchBox,
                    subjectBox,
                    faceBox,
                )
            }
        val hiding = (overlay as? FocusOverlay.Face)?.box
        val occluder =
            when (overlay) {
                is FocusOverlay.Subject -> overlay.box
                is FocusOverlay.Search -> overlay.box
                else -> subjectBox
            }
        _trackingHud.value =
            TrackingHud(
                overlay = overlay,
                sceneFaces = sceneFaces,
                dimmedFaces = SceneFacePolicy.dimmed(sceneFaces, hiding, occluder),
                isTracking = isTrackingActive,
            )
    }

    /** GET `0xA0` blob, patch `@2`, SET `0x9F`. Never invent the blob. */
    private suspend fun patchAudioDsp(name: String, patch: (ByteArray) -> ByteArray) {
        val got = sendKind(DjiNative.CMD_AUDIO_DSP_GET, null, "AudioDSP GET")
        val blob = CameraCommands.audioDspBytes(_status.value.audioDspBlob) ?: audioDspBlob
        if (!got || blob == null || blob.size <= 2) {
            _controlNote.value = "$name: no DSP blob"
            return
        }
        val next = patch(blob)
        val previousBlob = _status.value.audioDspBlob
        val previousAt2 = _status.value.audioDspAt2
        val previousWind = _status.value.windNr
        val previousDir = _status.value.directionalAudio
        _status.value = _status.value.applyingAudioBlob(next)
        val ok = sendKind(DjiNative.CMD_AUDIO_DSP_SET, CameraCommands.audioDspHex(next), name)
        if (!ok) {
            _status.value =
                _status.value.copy(
                    audioDspBlob = previousBlob,
                    audioDspAt2 = previousAt2,
                    windNr = previousWind,
                    directionalAudio = previousDir,
                )
            clearAudioPin(wind = true, directional = true)
        }
    }

    private fun pinAudio(
        channel: Int? = null,
        vocal: Int? = null,
        wind: Int? = null,
        directional: Int? = null,
    ) {
        val previous = audioPin
        audioPin =
            AudioPin(
                channel = channel ?: previous?.channel,
                vocal = vocal ?: previous?.vocal,
                wind = wind ?: previous?.wind,
                directional = directional ?: previous?.directional,
                deadlineElapsedMs = SystemClock.elapsedRealtime() + AudioPin.TTL_MS,
            )
    }

    private fun clearAudioPin(
        channel: Boolean = false,
        vocal: Boolean = false,
        wind: Boolean = false,
        directional: Boolean = false,
    ) {
        val pin = audioPin ?: return
        val next =
            pin.copy(
                channel = if (channel) null else pin.channel,
                vocal = if (vocal) null else pin.vocal,
                wind = if (wind) null else pin.wind,
                directional = if (directional) null else pin.directional,
            )
        audioPin = next.takeUnless { it.isEmpty() }
    }

    private fun enqueueAudio(work: suspend () -> Unit) {
        val previous = audioTail
        val generation = audioGeneration
        audioTail =
            scope.launch(EndpointCommandEpoch(generation)) {
                previous?.join()
                if (generation != audioGeneration) return@launch
                work()
            }
    }

    private suspend fun sendDumlWait(
        set: Int,
        cmd: Int,
        payload: ByteArray,
        name: String,
        receiver: Int = CameraCommands.RX_CAMERA,
        flags: Int = CameraCommands.FLAG_REQUEST,
    ): Boolean {
        ensureEndpointCommandCurrent(audioGeneration)
        val dl = datalink
        if (!controlLeaseAllows() || dl == null || !endpointCommandAdmission.allows(dl.isClosed, dl.isRebuilding)) {
            _controlNote.value = "not live"
            return false
        }
        _controlNote.value = null
        val key = opcodeKey(set, cmd)
        pairingHold.remove(key)
        try {
            val reply =
                try {
                    withTimeout(3_000) {
                        suspendCancellableCoroutine<DumlFrame> { cont ->
                            val waiter = FrameWaiter(setOf(key), cont)
                            waiters[key] = waiter
                            cont.invokeOnCancellation { waiters.remove(key) }
                            dl.sendDuml(set, cmd, payload, flags, receiver)
                            pairingHold.remove(key)?.let { held -> waiter.resume(held) }
                        }
                    }
                } catch (_: TimeoutCancellationException) {
                    ControlHud.timeoutNote(name, announce = false)?.let { _controlNote.value = it }
                    Log.i(TAG, "control: timeout $name — waiter saw no ACK")
                    return false
                }
            ensureEndpointCommandCurrent(audioGeneration)
            val parsed = CameraReply.parse(reply.payload)
            if (!parsed.isSuccess) {
                _controlNote.value = "$name: ${parsed.message}"
            }
            return parsed.isSuccess
        } finally {
            waiters.remove(key)
        }
    }

    private fun opcodeKey(set: Int, cmd: Int): Int = ((set and 0xFF) shl 8) or (cmd and 0xFF)

    /**
     * iOS `fireCamera`: latest-wins SET mailbox. Do not block [controlBusy], do
     * not toast a timeout; subscribe/pin is the HUD, a missed ACK is not a
     * revert. Retransmit at 300 ms, settle at 2 s.
     */
    private fun fireKind(
        kind: Int,
        extra: String?,
        name: String,
        coalesce: Boolean = false,
        retransmits: Boolean = true,
        onStage: ((ControlWireEvent) -> Unit)? = null,
        expect: (() -> Boolean)? = null,
        onFail: (() -> Unit)? = null,
        onSettle: ((Boolean) -> Unit)? = null,
    ) {
        val dl = datalink
        if (!controlLeaseAllows() || dl == null || !endpointCommandAdmission.allows(dl.isClosed, dl.isRebuilding)) {
            _controlNote.value = "not live"
            onStage?.invoke(ControlWireEvent.NOT_SENT)
            onFail?.invoke()
            onSettle?.invoke(false)
            if (appHost.debugBuild) debugCameraSetResult?.invoke(DjiNative.waitKey(kind), false)
            return
        }
        _controlNote.value = null
        val key = DjiNative.waitKey(kind)
        pairingHold.remove(key)
        val send =
            InflightSend(
                kind = kind,
                extra = extra,
                name = name,
                onFail = onFail,
                onSettle = onSettle,
                retransmits = retransmits,
                onStage = onStage,
                expect = expect,
            )
        if (coalesce && inflight.containsKey(key)) {
            // Latest wins: the replaced request never reaches the wire.
            inflightPending.put(key, send)?.onStage?.invoke(ControlWireEvent.NOT_SENT)
            return
        }
        launchInflight(key, send)
    }

    private fun launchInflight(key: Int, send: InflightSend) {
        inflight[key] = send
        inflightPending.remove(key)?.takeIf { it !== send }?.onStage?.invoke(ControlWireEvent.NOT_SENT)
        transmit(send)
        send.onStage?.invoke(ControlWireEvent.SENT)
        if (send.retransmits) {
            scope.launch {
                delay(300)
                if (inflight[key] === send && !send.retransmitted) {
                    send.retransmitted = true
                    transmit(send)
                }
            }
        }
        scope.launch {
            delay(2_000)
            if (inflight[key] === send) settleInflightTimeout(key, send)
        }
    }

    private fun transmit(send: InflightSend) {
        if (!controlLeaseAllows()) return
        val dl = datalink ?: return
        pairingHold.remove(DjiNative.waitKey(send.kind))
        try {
            val sentAt = SystemClock.elapsedRealtime()
            lastCameraSetAt = sentAt
            controlLease?.noteSet(sentAt)
            dl.sendCommand(send.kind, send.extra)
            Log.i(TAG, "control: send ${send.name}")
        } catch (e: Exception) {
            Log.w(TAG, "control: send ${send.name} failed", e)
        }
    }

    private fun finishInflight(send: InflightSend, reply: DumlFrame) {
        val key = reply.key
        if (inflight[key] !== send) return
        inflight.remove(key)
        val parsed = CameraReply.parse(reply.payload)
        val ok = parsed.isSuccess
        if (appHost.debugBuild) debugCameraSetResult?.invoke(key, ok)
        if (!ok) {
            send.onFail?.invoke()
            _controlNote.value = "${send.name}: ${parsed.message}"
        }
        send.onStage?.invoke(if (ok) ControlWireEvent.ACKNOWLEDGED else ControlWireEvent.REFUSED)
        send.onSettle?.invoke(ok)
        Log.i(TAG, "control: ${send.name} ack=${if (ok) "ok" else parsed.message}")
        inflightPending.remove(key)?.let { launchInflight(key, it) }
    }

    private fun settleInflightTimeout(key: Int, send: InflightSend) {
        if (inflight[key] !== send) return
        inflight.remove(key)
        if (appHost.debugBuild) debugCameraSetResult?.invoke(key, false)
        // iOS `ControlHud.timeoutNote(announce: false)`; never toast a SET timeout.
        Log.i(TAG, "control: ${send.name} — SET timeout, leave HUD")
        val zoomKey = DjiNative.waitKey(DjiNative.CMD_SET_ZOOM_LENS)
        val pollKey = DjiNative.waitKey(DjiNative.CMD_POLL_TRACKING)
        if (key != zoomKey && key != pollKey) {
            val videoFresh =
                datalink?.lastVideoPacketAt?.let {
                    SystemClock.elapsedRealtime() - it < LiveViewEnablePolicy.STALL_MS
                } == true
            if (videoFresh) {
                Log.i(TAG, "control: SET timeout with video flowing — leave UDP")
            } else if (datalink?.needsRebuild == true) {
                Log.i(TAG, "control: SET timeout after skipped UDP write — leave UDP")
            } else {
                noteCommandTimeout()
            }
        }
        // No ACK in the settle window. A SET that names its readback settles on what the
        // camera reports, never on success by default.
        val matched = send.expect?.invoke()
        send.onStage?.invoke(if (matched == true) ControlWireEvent.CONFIRMED else ControlWireEvent.UNCONFIRMED)
        send.onSettle?.invoke(matched ?: true)
        inflightPending.remove(key)?.let { launchInflight(key, it) }
    }

    /** iOS `CameraSession.noteCommandTimeout`. Encoder-pause (status young) must not tear UDP. */
    private fun noteCommandTimeout() {
        val now = SystemClock.elapsedRealtime()
        commandTimeoutsAt.removeAll { now - it >= LiveViewEnablePolicy.COMMAND_TIMEOUT_WINDOW_MS }
        commandTimeoutsAt.add(now)
        val videoAge = datalink?.lastVideoPacketAt?.let { now - it }
        val statusAge = datalink?.lastStatusAt?.let { now - it }
        val videoFresh = videoAge != null && videoAge < LiveViewEnablePolicy.STALL_MS
        val statusFresh = statusAge != null && statusAge < LiveViewEnablePolicy.STALL_MS
        val downlinkFresh =
            listOfNotNull(datalink?.lastStatusAt, datalink?.lastVideoPacketAt)
                .any { now - it < LiveViewEnablePolicy.COMMAND_TIMEOUT_WINDOW_MS }
        if (!LiveViewEnablePolicy.shouldRebuildAfterCommandTimeouts(
                timeoutsInWindow = commandTimeoutsAt.size,
                downlinkFresh = downlinkFresh,
                videoFresh = videoFresh,
                rebuildInFlight = datalink?.isRebuilding == true || feedRecoveryJob != null,
                sinceRebuildMs = datalink?.lastRebuildAt?.let { now - it },
                statusFresh = statusFresh,
            )
        ) {
            return
        }
        val sinceEnable = if (lastIdrRequest == 0L) null else now - lastIdrRequest
        if (LiveViewEnablePolicy.shouldHoldForGopReset(sinceEnable, videoAge)) {
            Log.i(TAG, "control: SET timeouts during GOP-reset grace — leave UDP")
            return
        }
        if (FocusTrackMode.shouldHoldWatchdog(lastFocusTrackAt?.let { (now - it) / 1000.0 })) {
            Log.i(TAG, "control: SET timeouts during AF-C grace — leave UDP")
            return
        }
        if (CamFov.shouldHoldWatchdog(
                lastZoomActivityAt?.let { (now - it) / 1000.0 },
                zoomPinchPreview != null,
            )
        ) {
            Log.i(TAG, "control: SET timeouts during zoom grace — leave UDP")
            return
        }
        if (CameraCommands.shouldHoldCameraSetWatchdog(
                lastCameraSetAt?.let { (now - it) / 1000.0 },
                videoAge?.div(1000.0),
            )
        ) {
            Log.i(TAG, "control: SET timeouts during SET grace — leave UDP")
            return
        }
        if (CameraCommands.shouldHoldGimbalWatchdog(
                lastGimbalThrowAt?.let { (now - it) / 1000.0 },
                videoAge?.div(1000.0),
                gimbalStickHeld,
            )
        ) {
            Log.i(TAG, "control: SET timeouts during gimbal grace — leave UDP")
            return
        }
        commandTimeoutsAt.clear()
        Log.i(TAG, "control: SET timeouts with video stale — rebuild UDP")
        endGimbalStick()
        startFeedRecovery {
            rebuildDatalinkKeepingPicture("command timeouts")
        }
    }

    /**
     * iOS `requestCamera`: true GET/SET round-trip (audio blobs, tap-focus burst).
     * Never [controlBusy], never toast a timeout.
     */
    private suspend fun sendKind(
        kind: Int,
        extra: String?,
        name: String,
        timeoutMs: Long = 3_000,
    ): Boolean {
        ensureEndpointCommandCurrent(audioGeneration)
        val dl = datalink
        if (!controlLeaseAllows() || dl == null || !endpointCommandAdmission.allows(dl.isClosed, dl.isRebuilding)) {
            _controlNote.value = "not live"
            return false
        }
        _controlNote.value = null
        val key = DjiNative.waitKey(kind)
        pairingHold.remove(key)
        try {
            val reply =
                try {
                    withTimeout(timeoutMs) {
                        suspendCancellableCoroutine<DumlFrame> { cont ->
                            val waiter = FrameWaiter(setOf(key), cont)
                            waiters[key] = waiter
                            cont.invokeOnCancellation { waiters.remove(key) }
                            dl.sendCommand(kind, extra)
                            pairingHold.remove(key)?.let { held -> waiter.resume(held) }
                        }
                    }
                } catch (_: TimeoutCancellationException) {
                    ControlHud.timeoutNote(name, announce = false)?.let { _controlNote.value = it }
                    Log.i(TAG, "control: timeout $name — waiter saw no ACK")
                    return false
                }
            ensureEndpointCommandCurrent(audioGeneration)
            val parsed = CameraReply.parse(reply.payload)
            if (!parsed.isSuccess) {
                _controlNote.value = "$name: ${parsed.message}"
            }
            return parsed.isSuccess
        } finally {
            waiters.remove(key)
        }
    }

    private fun shouldHold(frame: DumlFrame): Boolean =
        DumlHold.shouldHoldReply(frame.cmdSet, frame.cmdId)

    private suspend fun readWifiString(name: String, set: Int, cmd: Int, send: () -> Unit): String {
        val deadline = SystemClock.elapsedRealtime() + 30_000
        var last = "couldn't read the camera's Wi-Fi credentials"
        var attempt = 0
        while (SystemClock.elapsedRealtime() < deadline) {
            attempt += 1
            DjiLog.log("info", "session", "creds", "creds: $name attempt $attempt")
            send()
            try {
                val frame = waitFrame(set, cmd, 6_000)
                val value = DjiNative.unpackStatusString(frame.payload).orEmpty()
                if (value.isNotEmpty()) return value
                last = "$name came back empty (camera AP not up yet)"
            } catch (_: Exception) {
                last = "$name timed out: camera didn't reply (AP still coming up?)"
            }
            delay(400)
        }
        error(last)
    }

    private class InflightSend(
        val kind: Int,
        val extra: String?,
        val name: String,
        val onFail: (() -> Unit)?,
        val onSettle: ((Boolean) -> Unit)?,
        val retransmits: Boolean,
        var retransmitted: Boolean = false,
        /** Wire progress for the OpenCineCore seam. */
        val onStage: ((ControlWireEvent) -> Unit)? = null,
        /** The camera reports the requested value. */
        val expect: (() -> Boolean)? = null,
    )

    private class FrameWaiter(
        val keys: Set<Int>,
        private var continuation: Continuation<DumlFrame>?,
    ) {
        fun resume(frame: DumlFrame) {
            continuation?.resume(frame)
            continuation = null
        }

        fun resumeWithException(error: Throwable) {
            continuation?.resumeWithException(error)
            continuation = null
        }
    }

    companion object {
        private const val TAG = "PocketCameraSession"
        private const val IDENTITY_KEY = 0x0707
        private const val STATION_FIND_MS = 60_000L
        private const val STATION_SUBSCRIBE_SETTLE_MS = 150L
    }
}

private fun hexBytes(bytes: ByteArray): String = bytes.joinToString(" ") { "%02x".format(it.toInt() and 0xFF) }
