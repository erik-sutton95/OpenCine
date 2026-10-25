package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CameraRecordingFormat
import com.opencapture.opencine.core.CameraExposureProgram
import com.opencapture.opencine.core.CameraTimecode
import com.opencapture.opencine.core.CameraTimecodeReading
import com.opencapture.opencine.core.CapabilitySnapshot
import com.opencapture.opencine.core.CaptureMode
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandReceipt
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionAttemptID
import com.opencapture.opencine.core.ConnectionPhase
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.FocusMode
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.MediaState
import com.opencapture.opencine.core.MonitorLayoutCapabilities
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservationPrecision
import com.opencapture.opencine.core.OperationID
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SettingDescriptor
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingSemantics
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.media.HostShutterAngle
import com.opencapture.opencine.media.HostShutterPresentation
import com.opencapture.opencine.core.StorageVolume
import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.core.TimecodeCapability
import com.opencapture.opencine.core.TimecodePrecision
import com.opencapture.opencine.core.UnavailableReason
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.opencine.vocabulary.CameraCaptureProfile
import com.opencapture.opencine.vocabulary.CameraZoomProfile
import com.opencapture.opencine.vocabulary.CaptureCodecColorChoices
import com.opencapture.opencine.vocabulary.CaptureNativeISOCapabilities
import com.opencapture.opencine.vocabulary.ControlCapabilities
import com.opencapture.opencine.vocabulary.ControlFamily
import com.opencapture.opencine.core.rejection
import com.opencapture.opencine.motion.MonitorLayoutCapabilities
import com.opencapture.opencine.motion.MotionAxis
import com.opencapture.opencine.motion.MotionBounds
import com.opencapture.opencine.motion.MotionCapabilities
import com.opencapture.opencine.motion.MotionReferenceFrame
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.math.roundToInt
import kotlin.math.abs
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.nanoseconds
import kotlin.time.Duration.Companion.seconds
import com.opencapture.opencine.insta360.shell.ConnectionPhase as LinkPhase
import com.opencapture.opencine.insta360.shell.CameraCapability
import com.opencapture.opencine.vocabulary.ControlStatus
import com.opencapture.opencine.vocabulary.ControlCapability

/** The camera answered 500: it refused the request. */
internal class LunaRefused(code: Int) : IllegalStateException("Camera rejected command $code")

/**
 * The OpenCineCore session for one Luna camera: the single command path for its common controls
 * and the only source of their reported state. Port of Adapters/Insta360Apple
 * `LunaCameraSession.swift`; same slice (link and status, ISO, shutter, white balance, explicit
 * record start/stop) and same rules.
 *
 * ISO and shutter travel in one Luna exposure message, so the session owns both and composes
 * each write from the other's pending or reported value. An acknowledged write stays
 * `AwaitingObservation` until a readback shows it (`Confirmed`); when the settle window closes a
 * readback that still disagrees ends it `Failed(NOT_APPLIED)` and no readback at all `TimedOut`.
 * Nothing is ever written into the snapshot on request. State is guarded by one lock and never
 * held across a suspension.
 */
class LunaCameraSession internal constructor(
    private val send: suspend (LunaControl.Request) -> ByteArray,
    private val functionMode: () -> Int,
    private val readSettings: suspend () -> Unit,
    private val readCapture: suspend () -> Unit,
    private val scope: CoroutineScope,
    private val timing: Timing = Timing.LUNA,
    private val now: () -> MonotonicInstant = { MonotonicInstant(System.nanoTime().nanoseconds) },
    private val backendCapabilities: () -> Set<CameraCapability>? = { null },
    private val noteGimbalCommand: () -> Unit = {},
) : CameraSession {
    /**
     * How long an acknowledged write may take to show in readback, and how often to ask.
     * ponytail: the app's former pin windows plus readback margin; tune on hardware.
     */
    data class Timing(val settle: Map<SettingKey, Duration>, val readbackInterval: Duration) {
        companion object {
            val LUNA = Timing(
                mapOf(
                    SettingKey.ISO to 4.seconds, SettingKey.SHUTTER to 4.seconds,
                    SettingKey.WHITE_BALANCE to 6.seconds, SettingKey.RECORDING to 10.seconds,
                ),
                1.seconds,
            )
        }
    }

    private data class Awaiting(val intent: CameraCommandIntent, val acceptedAt: MonotonicInstant,
        val deadline: MonotonicInstant, val shutterDenominator: Int?)

    override val id: CameraSessionID = CameraSessionID()
    private val lock = Any()
    private var current = CameraSnapshot(id, connection = ConnectionState.Connecting(ConnectionAttemptID(), ConnectionPhase.LINK))
    private val feed = MutableStateFlow(current)
    override val snapshots: StateFlow<CameraSnapshot> = feed.asStateFlow()

    /** Integration media commands use this actual session lifetime and transport path. */
    internal suspend fun mediaRequest(request: LunaControl.Request, epoch: ControlEpoch): ByteArray {
        fun checkOwner() {
            synchronized(lock) {
                check(!closed && current.connection == ConnectionState.Ready &&
                    current.authority == ControlAuthority.Owner && current.epoch == epoch) {
                    "The media source session retired."
                }
            }
        }
        currentCoroutineContext().ensureActive(); checkOwner()
        val reply = send(request)
        currentCoroutineContext().ensureActive(); checkOwner()
        return reply
    }

    /** One motion request on this exact session/epoch; callbacks cannot authorize a successor. */
    internal suspend fun motionRequest(request: LunaControl.Request, epoch: ControlEpoch,
        commanding: Boolean = false): ByteArray {
        fun checkOwner() {
            synchronized(lock) {
                check(!closed && current.connection == ConnectionState.Ready &&
                    current.authority == ControlAuthority.Owner && current.epoch == epoch) {
                    "The motion source session retired."
                }
            }
        }
        currentCoroutineContext().ensureActive(); checkOwner()
        if (commanding) noteGimbalCommand()
        currentCoroutineContext().ensureActive(); checkOwner()
        val reply = send(request)
        currentCoroutineContext().ensureActive(); checkOwner()
        return reply
    }

    /** Recording colour profile (option 35) as a namespaced id; camera-reported or unknown. */
    @Volatile var recordingProfile: ObservedValue<String> = ObservedValue.unknown
        private set

    private var shootingMode: LunaShootingMode? = null
    private var shutterPresentation = HostShutterPresentation.CAMERA_VALUE
    private var reportedShutter: ObservedValue<ShutterValue> = ObservedValue.unknown
    private var reportedCadence: ObservedValue<Double> = ObservedValue.unknown
    /** The last card list and when it arrived; option 99 rebuilds the volumes from it. */
    private var reportedCards: Pair<List<LunaStorage>, MonotonicInstant>? = null
    /** Photography option 99: remaining record seconds per card location, and when it arrived. */
    private var reportedRemaining: Pair<Map<Long, Long>, MonotonicInstant>? = null

    /** One volume per reported card, each with its own camera-reported remaining record time. */
    private fun projectStorage() {
        val (cards, at) = reportedCards ?: return
        current = current.copy(storage = ObservedValue(cards.map { card ->
            volume(card, at, reportedRemaining?.let { (seconds, reported) -> seconds[card.location]?.let { it to reported } })
        }, ObservationOrigin.CAMERA_REPORTED, at))
    }
    private var zoomDomain: ClosedFloatingPointRange<Double>? = null
    private val reportedAt = mutableMapOf<SettingKey, MonotonicInstant>()
    private val receipts = mutableMapOf<OperationID, CommandReceipt>()
    private val awaiting = mutableMapOf<OperationID, Awaiting>()
    private val targets = mutableMapOf<SettingKey, Pair<OperationID, SettingValue>>()
    private val waiters = mutableMapOf<OperationID, CompletableDeferred<CommandReceipt>>()
    private var pump: Job? = null
    private var closed = false

    init {
        synchronized(lock) {
            refreshCapabilities()
            publish()
        }
    }

    // Link and telemetry (from the backend).

    /** The operator's display choice changes no camera setting; emulation requires reported inputs. */
    fun configureShutter(presentation: HostShutterPresentation) {
        synchronized(lock) {
            if (closed || shutterPresentation == presentation) return
            shutterPresentation = presentation
            projectShutter()
            refreshCapabilities()
            publish()
        }
    }

    /** Configured connection lens range; absent/invalid ranges leave zoom undescribed. */
    fun configureLens(zoomDomain: ClosedFloatingPointRange<Double>?) {
        synchronized(lock) {
            if (closed) return
            this.zoomDomain = zoomDomain?.takeIf {
                it.start.isFinite() && it.endInclusive.isFinite() && it.start >= 1.0 &&
                    it.endInclusive <= LunaControl.MAXIMUM_ZOOM && it.start <= it.endInclusive
            }
            refreshCapabilities()
            publish()
        }
    }

    /** The backend's link phase. LIVE is a usable control link and a new control epoch. */
    internal fun linkChanged(phase: LinkPhase, serial: String? = null) {
        synchronized(lock) {
            if (closed) return
            when (phase) {
                LinkPhase.SCANNING -> return
                LinkPhase.IDLE, LinkPhase.FAILED -> {
                    if (current.connection != ConnectionState.Ready) return
                    endInFlight()
                    current = current.copy(
                        connection = ConnectionState.Recovering(ConnectionAttemptID()),
                        authority = ControlAuthority.Unavailable(UnavailableReason.Link),
                    )
                }
                LinkPhase.CONNECTING_GATT, LinkPhase.PAIRING -> connecting(ConnectionPhase.NEGOTIATING)
                LinkPhase.AWAITING_APPROVAL -> connecting(ConnectionPhase.AWAITING_APPROVAL)
                LinkPhase.READING_WIFI_CREDS, LinkPhase.JOINING_WIFI -> connecting(ConnectionPhase.JOINING_NETWORK)
                LinkPhase.OPENING_DATALINK -> connecting(ConnectionPhase.LINK)
                LinkPhase.LIVE -> current = current.copy(
                    device = serial?.takeIf { it.isNotEmpty() }?.let { CameraDeviceID.durable(it, INTEGRATION) } ?: current.device,
                    connection = ConnectionState.Ready, authority = ControlAuthority.Owner, epoch = current.epoch.next(),
                )
            }
            // Frame-derived clock observations belong to this link, never its predecessor.
            current = current.withTimecodeReading(ObservedValue.unknown)
            publish()
        }
    }

    internal fun ingest(device: LunaDeviceStatus) {
        synchronized(lock) {
            if (closed) return
            val at = now()
            device.shootingMode?.let {
                // Remaining time is per function mode: another bank's report no longer applies.
                if (it.functionMode != shootingMode?.functionMode) reportedRemaining = null
                shootingMode = it
                current = current.copy(mode = ObservedValue(captureMode(it), ObservationOrigin.CAMERA_REPORTED, at))
            }
            device.battery?.let { battery ->
                current = current.copy(
                    power = current.power.copy(
                        battery = ObservedValue(
                            minOf(battery.percent, 100L) / 100.0, ObservationOrigin.CAMERA_REPORTED, at,
                            precision = ObservationPrecision.Quantized(0.01),
                        ),
                        // Power type names the adapter; "charging" itself is not reported.
                        externalPower = ObservedValue(battery.powerType != 0L, ObservationOrigin.PROTOCOL_DERIVED, at),
                    ),
                )
            }
            val volumes = device.storageList.ifEmpty { listOfNotNull(device.storage) }
            if (volumes.isNotEmpty()) {
                reportedCards = volumes to at
                projectStorage()
            }
            projectShutter()
            refreshCapabilities()
            publish()
        }
    }

    internal fun ingest(settings: LunaPhotographySettings) {
        synchronized(lock) {
            if (closed) return
            // A reply for another mode's settings bank says nothing about the active one.
            settings.functionMode?.let { if (it != functionMode()) return }
            val at = now()
            fun carries(type: Int) = settings.types.isEmpty() || type in settings.types
            // Option 99 rides its own poll; a reply that does not carry it keeps the last report.
            if (LunaControl.REMAINING_TIME in settings.types || settings.remainingRecordTime.isNotEmpty()) {
                reportedRemaining = settings.remainingRecordTime.associate { (seconds, location) -> location to seconds } to at
                projectStorage()
            }
            if (carries(31) && (settings.recordResolution != null || 31 in settings.types)) {
                val cadence = settings.videoResolution?.framesPerSecond
                if (reportedCadence.value != cadence) {
                    current = current.copy(capabilities = current.capabilities.copy(revision = current.capabilities.revision.next()))
                }
                reportedCadence = cadence?.let { ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, at) }
                    ?: ObservedValue.unknown
            }
            val still = settings.stillExposure.takeIf { carries(20) }
            val video = settings.videoExposure.takeIf { carries(21) }
            val exposure = if (shootingMode?.isPhoto == true) still ?: video else video ?: still
            val values = current.settings.toMutableMap()
            var recordingFormat = current.recordingFormat
            var program = current.exposureProgram
            if (exposure != null || 20 in settings.types || 21 in settings.types) {
                val iso = exposure?.let(::iso)
                val shutter = exposure?.let(::shutter)
                values[SettingKey.ISO] = iso?.let { ObservedValue(SettingValue.Iso(it), ObservationOrigin.CAMERA_REPORTED, at) } ?: ObservedValue.unknown
                reportedShutter = shutter?.let { ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, at) } ?: ObservedValue.unknown
                program = exposure?.let(::exposureProgram)?.let { ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, at) } ?: ObservedValue.unknown
                if (iso == null) reportedAt.remove(SettingKey.ISO) else reportedAt[SettingKey.ISO] = at
                if (shutter == null) reportedAt.remove(SettingKey.SHUTTER) else reportedAt[SettingKey.SHUTTER] = at
            }
            if (carries(39)) {
                // proto3 may omit a zero: a requested type 39 without a value is Auto.
                val kelvin = settings.whiteBalanceKelvin
                (kelvin ?: if (39 in settings.types) 0L else null)?.let { reported ->
                    val value = if (reported == 0L) WhiteBalanceValue.Auto else WhiteBalanceValue.Kelvin(reported.toInt())
                    val origin = if (kelvin == null) ObservationOrigin.PROTOCOL_DERIVED else ObservationOrigin.CAMERA_REPORTED
                    values[SettingKey.WHITE_BALANCE] = ObservedValue(SettingValue.WhiteBalance(value), origin, at)
                    reportedAt[SettingKey.WHITE_BALANCE] = at
                }
            }
            // Option 31 declares recording dimensions and cadence, not the preview's encoding.
            if (carries(31) && (settings.recordResolution != null || 31 in settings.types)) {
                val resolution = settings.videoResolution
                val rate = resolution?.let { Rational.frameRate(it.framesPerSecond) }
                values[SettingKey.FRAME_RATE] = rate?.let {
                    ObservedValue(SettingValue.FrameRate(it), ObservationOrigin.CAMERA_REPORTED, at)
                } ?: ObservedValue.unknown
                if (rate == null) reportedAt.remove(SettingKey.FRAME_RATE) else reportedAt[SettingKey.FRAME_RATE] = at
                val dimensions = resolution?.let { CameraRecordingFormat.Dimensions.measured(it.width, it.height) }
                recordingFormat = recordingFormat.copy(dimensions = dimensions?.let {
                    ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, at)
                } ?: ObservedValue.unknown)
            }
            if (carries(35) && (settings.colorMode != null || 35 in settings.types)) {
                recordingProfile = settings.colorMode?.let(::profileID)?.let {
                    ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, at)
                } ?: ObservedValue.unknown
                recordingFormat = recordingFormat.copy(profile = settings.colorMode?.let(::recordingProfileLabel)?.let {
                    ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, at)
                } ?: ObservedValue.unknown)
            }
            if (carries(53) && (settings.zoom != null || 53 in settings.types)) {
                val zoom = settings.zoom?.takeIf { it.isFinite() && it in 1.0..LunaControl.MAXIMUM_ZOOM }
                values[SettingKey.ZOOM] = zoom?.let {
                    ObservedValue(SettingValue.Zoom(it), ObservationOrigin.CAMERA_REPORTED, at)
                } ?: ObservedValue.unknown
                if (zoom != null) reportedAt[SettingKey.ZOOM] = at else reportedAt.remove(SettingKey.ZOOM)
            }
            if (carries(93) && (settings.afMode != null || 93 in settings.types)) {
                val focus = when (settings.afMode) {
                    1L -> FocusMode.SINGLE
                    3L -> FocusMode.CONTINUOUS
                    else -> null // Product Showcase remains an integration-owned extension.
                }
                values[SettingKey.FOCUS_MODE] = focus?.let {
                    ObservedValue(SettingValue.FocusMode(it), ObservationOrigin.CAMERA_REPORTED, at)
                } ?: ObservedValue.unknown
                if (focus != null) reportedAt[SettingKey.FOCUS_MODE] = at else reportedAt.remove(SettingKey.FOCUS_MODE)
            }
            current = current.copy(settings = values, recordingFormat = recordingFormat, exposureProgram = program)
            projectShutter()
            refreshCapabilities()
            // The waiters this settle finishes must not run before the snapshot that
            // carries the reported values is published; otherwise an eager awaiter sees
            // the previous feed. Publish exactly once, then complete the captured waiters.
            val finished = mutableListOf<Pair<CompletableDeferred<CommandReceipt>, CommandReceipt>>()
            settle(finished)
            publish()
            for ((waiter, receipt) in finished) waiter.complete(receipt)
        }
    }

    internal fun ingest(capture: LunaCaptureStatus) {
        synchronized(lock) {
            if (closed) return
            val at = now()
            // Photo and pano capture states say nothing about video recording: unknown.
            val state = when {
                capture.isRecording -> RecordingState.RECORDING
                capture.isIdle -> RecordingState.IDLE
                else -> null
            }
            current = current.copy(recording = state?.let { ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, at) } ?: ObservedValue.unknown)
            if (state != null) reportedAt[SettingKey.RECORDING] = at
            // Same publish-before-waiter order as the settings ingest above.
            val finished = mutableListOf<Pair<CompletableDeferred<CommandReceipt>, CommandReceipt>>()
            settle(finished)
            publish()
            for ((waiter, receipt) in finished) waiter.complete(receipt)
        }
    }

    /**
     * Time of day the host derives for the live picture: the phone sets the camera clock and pins
     * frame stamps to its own, so the value is `CLOCK_DERIVED`, never a camera counter.
     */
    fun ingest(timecode: CameraTimecode) = ingest(CameraTimecodeReading(timecode))

    fun ingest(timecode: CameraTimecodeReading) {
        synchronized(lock) {
            if (closed || current.connection != ConnectionState.Ready) return
            current = current.withTimecodeReading(ObservedValue(timecode, ObservationOrigin.CLOCK_DERIVED, now()))
            publish()
        }
    }

    /**
     * What a monitor lays out for this camera (Swift `layout(base:)`): a view of the one control
     * model ([controlCapabilities]), so the zoom chip follows Luna's declared zoom before the live
     * range arrives. [base] carries what Core has no vocabulary for yet.
     */
    fun layout(base: MonitorLayoutCapabilities = MonitorLayoutCapabilities()): MonitorLayoutCapabilities =
        com.opencapture.opencine.vocabulary.MonitorLayoutCapabilities(controlCapabilities(), base)

    /**
     * The one control model for this camera (Swift `controlCapabilities(codecColor:)`):
     * [CAPTURE_PROFILE] and [MOTION] merged with the live capabilities. [codecColor] is what the
     * codec and colour popup lists now, when the host has it.
     */
    fun controlCapabilities(codecColor: CaptureCodecColorChoices? = null): ControlCapabilities {
        val capabilities = synchronized(lock) { current.capabilities }
        return Companion.controlCapabilities(capabilities, backendCapabilities(), codecColor)
    }

    // CameraSession.

    override suspend fun submit(command: CameraCommand): CommandReceipt {
        val operation = command.operation
        val key = command.intent.key
        val request: LunaControl.Request
        val expectedShutter: Int?
        synchronized(lock) {
            receipts[operation]?.let { return it }
            receipts[operation] = CommandReceipt(
                operation, id, command.intent,
                confirmation = current.capabilities[key]?.semantics?.confirmation ?: SettingSemantics.Confirmation.READBACK,
            )
            if (closed) return transition(operation, CommandStage.Rejected(CommandRejection.SessionClosed))
            current.rejection(command, now())?.let { return transition(operation, CommandStage.Rejected(it)) }
            transition(operation, CommandStage.Admitted)
            // Idempotency: a start while the camera reports recording (or a stop while idle) is
            // already satisfied, so a retry can never undo the first success.
            if (alreadyReported(command.intent)) return transition(operation, CommandStage.Confirmed)
            // A described key without a request here is the old silent "unsupported" hole; the
            // capability test submits every writable key to catch it.
            request = try {
                buildRequest(command.intent) ?: return transition(operation, CommandStage.Rejected(CommandRejection.Unsupported))
            } catch (_: IllegalArgumentException) {
                return transition(operation, CommandStage.Rejected(CommandRejection.OutOfDomain))
            }
            val angle = ((command.intent as? CameraCommandIntent.Set)?.value as? SettingValue.Shutter)?.value as? ShutterValue.Angle
            expectedShutter = angle?.let { HostShutterAngle.denominator(it.degrees, reportedCadence.value, SHUTTER_DENOMINATORS) }
            (command.intent as? CameraCommandIntent.Set)?.let { set ->
                // An older unfinished write to the same setting may or may not have landed
                // before this one; only the newest receipt can confirm.
                targets[key]?.first?.let { transition(it, CommandStage.Failed(CommandFailure.SUPERSEDED)) }
                targets[key] = operation to set.value
            }
            transition(operation, CommandStage.Sent)
        }
        try {
            send(request)
        } catch (refused: LunaRefused) {
            return synchronized(lock) { transition(operation, CommandStage.Rejected(CommandRejection.CameraRefused)) }
        } catch (cancelled: CancellationException) {
            // A request timeout or a closed channel also arrives as cancellation; only the
            // caller's own cancellation propagates. Either way the camera may have acted.
            val unknown = synchronized(lock) { transition(operation, CommandStage.OutcomeUnknown) }
            currentCoroutineContext().ensureActive()
            return unknown
        } catch (_: Exception) {
            // Timeout or dropped link: the camera may have acted.
            return synchronized(lock) { transition(operation, CommandStage.OutcomeUnknown) }
        }
        synchronized(lock) {
            // The link dropped or the session closed while the write was out.
            receipts.getValue(operation).takeIf { it.isFinished }?.let { return it }
            transition(operation, CommandStage.Accepted)
            val acceptedAt = now()
            var deadline = acceptedAt + (timing.settle[key] ?: 4.seconds)
            command.preconditions.deadline?.let { if (it < deadline) deadline = it }
            awaiting[operation] = Awaiting(command.intent, acceptedAt, deadline, expectedShutter)
            transition(operation, CommandStage.AwaitingObservation)
            settle()
            if (pump?.isActive != true) pump = scope.launch { readBackUntilSettled() }
            return receipts.getValue(operation)
        }
    }

    override suspend fun outcome(operation: OperationID): CommandReceipt? {
        val waiter = synchronized(lock) {
            val receipt = receipts[operation] ?: return null
            if (receipt.isFinished) return receipt
            waiters.getOrPut(operation) { CompletableDeferred() }
        }
        return waiter.await()
    }

    override fun receipt(operation: OperationID): CommandReceipt? = synchronized(lock) { receipts[operation] }

    /** Never sends a camera command; in particular it never stops a recording. */
    override suspend fun close(reason: SessionCloseReason): Unit = closeNow(reason)

    override fun closeNow(reason: SessionCloseReason) {
        synchronized(lock) {
            if (closed) return
            endInFlight()
            closed = true
            pump?.cancel()
            current = current.copy(
                connection = ConnectionState.Disconnected(reason),
                authority = ControlAuthority.Unavailable(UnavailableReason.Link),
            )
            publish()
        }
    }

    // Requests.

    private fun buildRequest(intent: CameraCommandIntent): LunaControl.Request? {
        val bank = functionMode()
        return when (intent) {
            is CameraCommandIntent.Set -> when (val value = intent.value) {
                is SettingValue.Iso -> exposure(value.value, (target(SettingKey.SHUTTER) as? SettingValue.Shutter)?.value, bank)
                is SettingValue.Shutter -> exposure((target(SettingKey.ISO) as? SettingValue.Iso)?.value, value.value, bank)
                is SettingValue.Zoom -> LunaControl.zoom(value.ratio, bank)
                is SettingValue.FocusMode -> when (value.mode) {
                    FocusMode.SINGLE -> LunaControl.afMode(1, bank)
                    FocusMode.CONTINUOUS -> LunaControl.afMode(3, bank)
                    FocusMode.MANUAL -> null
                }
                is SettingValue.WhiteBalance -> when (val balance = value.value) {
                    WhiteBalanceValue.Auto -> LunaControl.whiteBalanceAuto(bank)
                    is WhiteBalanceValue.Kelvin -> LunaControl.whiteBalanceKelvin(balance.kelvin.toLong(), bank)
                    is WhiteBalanceValue.Preset -> null
                }
                else -> null
            }
            CameraCommandIntent.StartRecording -> shootingMode?.let(LunaControl::startCapture)
            CameraCommandIntent.StopRecording -> shootingMode?.let(LunaControl::stopCapture)
            is CameraCommandIntent.FocusPoint -> null
        }
    }

    /** The newest unfinished write for [key], else the reported value. */
    private fun target(key: SettingKey): SettingValue? = targets[key]?.second ?: current.value(key).value

    private fun exposure(iso: ISOValue?, shutter: ShutterValue?, bank: Int): LunaControl.Request? {
        val manualIso = (iso as? ISOValue.Manual)?.iso?.toLong()
        val seconds = when (val value = shutter ?: reportedShutter.value) {
            is ShutterValue.Angle -> {
                // An angle from Auto is the first manual shutter; the reported cadence composes it.
                if (shutterPresentation != HostShutterPresentation.EMULATED_ANGLE ||
                    shootingMode?.isPhoto != false) return null
                val denominator = HostShutterAngle.denominator(value.degrees, reportedCadence.value, SHUTTER_DENOMINATORS)
                    ?: return null
                1.0 / denominator
            }
            is ShutterValue.Duration -> value.seconds.doubleValue
            ShutterValue.Auto -> null
            null -> return null
        }
        return LunaControl.videoExposure(LunaControl.exposureProgram(manualIso, seconds), manualIso, seconds, bank)
    }

    // Settling.

    private fun alreadyReported(intent: CameraCommandIntent) = when (intent) {
        CameraCommandIntent.StartRecording -> current.recording.value == RecordingState.RECORDING
        CameraCommandIntent.StopRecording -> current.recording.value == RecordingState.IDLE
        else -> false
    }

    private fun reportShows(intent: CameraCommandIntent, shutterDenominator: Int?) = when (intent) {
        is CameraCommandIntent.Set -> when (val target = intent.value) {
            is SettingValue.Zoom -> (current.value(SettingKey.ZOOM).value as? SettingValue.Zoom)?.let {
                abs(target.ratio - it.ratio) < 0.05
            } == true
            is SettingValue.Shutter -> if (target.value is ShutterValue.Angle) {
                shutterDenominator != null && (reportedShutter.value as? ShutterValue.Duration)?.seconds == Rational(1, shutterDenominator)
            // An angle projection never equals a duration or Auto: the camera's own value confirms.
            } else reportedShutter.value == target.value
            else -> current.value(target.key).value == target
        }
        CameraCommandIntent.StartRecording -> current.recording.value == RecordingState.RECORDING
        CameraCommandIntent.StopRecording -> current.recording.value == RecordingState.IDLE
        is CameraCommandIntent.FocusPoint -> false
    }

    /** Confirms what a readback shows; ends what its settle window has closed on. */
    private fun settle(finished: MutableList<Pair<CompletableDeferred<CommandReceipt>, CommandReceipt>>? = null) {
        val at = now()
        for ((operation, write) in awaiting.toList()) {
            if (reportShows(write.intent, write.shutterDenominator)) {
                transition(operation, CommandStage.Confirmed, finished)
            } else if (at >= write.deadline) {
                val heard = reportedAt[write.intent.key]?.let { it > write.acceptedAt } == true
                transition(operation, if (heard) CommandStage.Failed(CommandFailure.NOT_APPLIED) else CommandStage.TimedOut, finished)
            }
        }
    }

    private suspend fun readBackUntilSettled() {
        while (true) {
            val keys = synchronized(lock) {
                if (closed || awaiting.isEmpty()) return
                awaiting.values.map { it.intent.key }.toSet()
            }
            if (SettingKey.RECORDING in keys) readCapture()
            if ((keys - SettingKey.RECORDING).isNotEmpty()) readSettings()
            delay(timing.readbackInterval)
            synchronized(lock) { settle() }
        }
    }

    /** Link lost or session closed: unsent work never left; sent work may have acted. */
    private fun endInFlight() {
        for ((operation, receipt) in receipts.toList()) {
            if (receipt.isFinished) continue
            transition(
                operation,
                when (receipt.stage) {
                    CommandStage.Created, CommandStage.Admitted -> CommandStage.Failed(CommandFailure.NOT_SENT)
                    else -> CommandStage.OutcomeUnknown
                },
            )
        }
    }

    private fun connecting(phase: ConnectionPhase) {
        val attempt = when (val connection = current.connection) {
            is ConnectionState.Connecting -> connection.attempt
            is ConnectionState.Recovering -> connection.attempt
            else -> {
                endInFlight()
                ConnectionAttemptID()
            }
        }
        current = current.copy(
            connection = if (current.epoch.value == 0L) ConnectionState.Connecting(attempt, phase) else ConnectionState.Recovering(attempt),
            authority = ControlAuthority.Unavailable(UnavailableReason.Link),
        )
    }

    private fun transition(operation: OperationID, stage: CommandStage,
        finished: MutableList<Pair<CompletableDeferred<CommandReceipt>, CommandReceipt>>? = null): CommandReceipt {
        val receipt = receipts.getValue(operation)
        // A late completion never rewrites a finished outcome.
        if (receipt.isFinished) return receipt
        val next = receipt.copy(stage = stage)
        receipts[operation] = next
        if (next.isFinished) {
            awaiting.remove(operation)
            if (targets[next.intent.key]?.first == operation) targets.remove(next.intent.key)
            val waiter = waiters.remove(operation)
            if (waiter != null) {
                // A reporting caller publishes before completing its waiters, so an eager
                // awaiter observes the snapshot the outcome belongs to; other callers keep
                // the immediate completion.
                if (finished != null) finished.add(waiter to next) else waiter.complete(next)
            }
        }
        return next
    }

    private fun publish() {
        current = current.copy(revision = current.revision.next())
        feed.value = current
    }

    // Capabilities and mapping.

    private fun projectShutter() {
        val value = reportedShutter.value
        val projected: ObservedValue<SettingValue> = when {
            value == null -> ObservedValue.unknown
            // Photo has no cadence to emulate against: it keeps the camera's own duration.
            shutterPresentation == HostShutterPresentation.EMULATED_ANGLE && value is ShutterValue.Duration &&
                shootingMode?.isPhoto != true -> {
                val cadence = reportedCadence.value
                val angle = if (shootingMode?.isPhoto == false && cadence != null)
                    HostShutterAngle.reported(value.seconds, cadence) else null
                angle?.let { ObservedValue(SettingValue.Shutter(ShutterValue.Angle(it)), ObservationOrigin.PROTOCOL_DERIVED,
                    listOfNotNull(reportedShutter.observedAt, reportedCadence.observedAt).minOrNull()) }
                    ?: ObservedValue.unknown
            }
            else -> ObservedValue(SettingValue.Shutter(value), reportedShutter.origin, reportedShutter.observedAt)
        }
        current = current.copy(settings = current.settings + (SettingKey.SHUTTER to projected))
    }

    private fun refreshCapabilities() {
        // A write carries ISO and shutter together, so neither is safe before both are known. A
        // withdrawn report keeps its key with an unknown value, so the value decides.
        val exposure = if (current.value(SettingKey.ISO).value != null) Availability.Available else Availability.Unavailable(UnavailableReason.NotReady)
        val emulated = shutterPresentation == HostShutterPresentation.EMULATED_ANGLE
        // Angle is a presentation: the camera's durations and Auto stay writable (an angle pick,
        // Manual from Auto, AE-L), so Auto never blocks the first manual shutter, and a missing
        // cadence withholds only the angles (CodeRabbit on #114). Swift twin.
        val shutterAvailability =
            if (emulated && shootingMode == null) Availability.Unavailable(UnavailableReason.NotReady) else exposure
        // Angles are offered only where `exposure()` can compose them: video with a reported cadence.
        val offersAngles = emulated && shootingMode?.isPhoto == false && reportedCadence.value != null
        val nativeShutter = listOf<SettingValue>(SettingValue.Shutter(ShutterValue.Auto)) +
            SHUTTER_DENOMINATORS.map { SettingValue.Shutter(ShutterValue.Duration(Rational(1, it))) }
        val recording = when {
            shootingMode == null -> Availability.Unavailable(UnavailableReason.NotReady)
            shootingMode?.isPhoto == true -> Availability.Unavailable(UnavailableReason.Mode)
            else -> Availability.Available
        }
        val descriptors = mutableListOf(
            SettingDescriptor(
                SettingKey.ISO, availability = exposure,
                domain = SettingDomain(listOf<SettingValue>(SettingValue.Iso(ISOValue.Auto)) + ISO_VALUES.map { SettingValue.Iso(ISOValue.Manual(it)) }),
            ),
            SettingDescriptor(
                SettingKey.SHUTTER, availability = shutterAvailability,
                semantics = SettingSemantics(implementation = if (emulated) SettingSemantics.Implementation.EMULATED else SettingSemantics.Implementation.NATIVE),
                domain = SettingDomain(if (offersAngles) HostShutterAngle.choices + nativeShutter else nativeShutter),
            ),
            SettingDescriptor(
                SettingKey.WHITE_BALANCE,
                domain = SettingDomain(listOf(SettingValue.WhiteBalance(WhiteBalanceValue.Auto)), range = 2000.0..10000.0),
            ),
            SettingDescriptor(SettingKey.RECORDING, availability = recording),
            SettingDescriptor(
                SettingKey.FOCUS_MODE,
                domain = SettingDomain(listOf(SettingValue.FocusMode(FocusMode.SINGLE), SettingValue.FocusMode(FocusMode.CONTINUOUS))),
            ),
            // The record rate is a common read-only observation; the format picker stays native.
            SettingDescriptor(SettingKey.FRAME_RATE, access = SettingAccess.READ_ONLY),
        )
        zoomDomain?.let { descriptors += SettingDescriptor(SettingKey.ZOOM, domain = SettingDomain(range = it)) }
        // Timecode is host-derived time of day ([ingest]); Luna reports no audio levels.
        val declared = CapabilitySnapshot(
            revision = current.capabilities.revision, descriptors = descriptors,
            timecodeCapability = TimecodeCapability.supported(TimecodePrecision.Seconds), audioLevels = SupportStatus.UNSUPPORTED,
        )
        if (declared == current.capabilities) return
        current = current.copy(capabilities = declared.copy(revision = declared.revision.next()))
    }

    companion object {
        /**
         * Derives controls from camera facts and the backend's current verified operation domains.
         * Null means no backend declaration. Video/audio transport and the host clock are not controls.
         * Swift: `controlCapabilities(snapshot:backendCapabilities:codecColor:)`.
         */
        fun controlCapabilities(snapshot: CapabilitySnapshot, backendCapabilities: Set<CameraCapability>?,
            codecColor: CaptureCodecColorChoices? = null): ControlCapabilities {
            val controls = ControlCapabilities.derive(snapshot, CAPTURE_PROFILE, MOTION, codecColor)
            if (backendCapabilities == null) return controls
            val domains = listOf(
                CameraCapability.CAMERA_SETTINGS to listOf(ControlFamily.ISO, ControlFamily.SHUTTER,
                    ControlFamily.WHITE_BALANCE, ControlFamily.TINT, ControlFamily.FOCUS,
                    ControlFamily.EXPOSURE_COMPENSATION, ControlFamily.FACE_METERING,
                    ControlFamily.RECORDING_FORMAT, ControlFamily.CODEC_COLOR),
                CameraCapability.FOCUS to listOf(ControlFamily.TAP_FOCUS),
                CameraCapability.ZOOM to listOf(ControlFamily.ZOOM),
                CameraCapability.GIMBAL to listOf(ControlFamily.GIMBAL, ControlFamily.HEAD_TRACKING),
                CameraCapability.RECORD to listOf(ControlFamily.RECORDING),
                CameraCapability.CAMERA_MEDIA to listOf(ControlFamily.MEDIA, ControlFamily.MEDIA_DELETE),
            )
            val inputs = domains.flatMap { (domain, families) ->
                val status = ControlStatus(if (domain in backendCapabilities) SupportStatus.SUPPORTED else SupportStatus.UNSUPPORTED)
                families.map { it to status }
            }.toMap()
            val restricted = controls.restricting(inputs)
            // Preserve the existing shell declaration for this native extension, in its typed offer.
            return restricted.copy(iso = ControlCapability(restricted.iso.support, restricted.iso.access,
                restricted.iso.offer?.copy(nativeISO = restricted.nativeISO.copy(
                    hop = CameraCapability.NATIVE_ISO_HOP in backendCapabilities))))
        }

        /**
         * What Luna Ultra (fw 1.1.15) declares to shared motion (Swift `LunaCameraSession.motion`):
         * handle-frame pan and tilt (cmd 226 SET_ANGLE), pitch -57...90, yaw one arc from about
         * -125 through 180 to -58.5 (unwrapped -58.5...235), no zoom in moves, no client rate cap
         * (each SET re-plans), its GET_ANGLE is the pose (older than 0.3 s is not feedback), aim
         * ends within 0.5 degrees.
         */
        val MOTION = MotionCapabilities(
            axes = setOf(MotionAxis.PAN, MotionAxis.TILT), frame = MotionReferenceFrame.HANDLE,
            bounds = MotionBounds(-58.5..235.0, -57.0..90.0),
            maxRateDegPerSec = null, feedbackMaxAge = 300.milliseconds, arrivalToleranceDeg = 0.5,
            pose = SupportStatus.SUPPORTED,
        )
        /**
         * Luna's static control facts (fw 1.1.15; Swift `LunaCameraSession.captureProfile`): focus
         * modes and tap focus, a fixed aperture, the gimbal, zoom presets 1/2/3/6/15, face
         * metering, native exposure compensation, no native ISO hop or ISO ceiling, no ND, photo
         * modes, the camera's media served and deleted over its access point. Multiview is not
         * declared (unknown).
         */
        val CAPTURE_PROFILE = CameraCaptureProfile(
            supportsFocusMode = true, supportsTapFocus = true, supportsAperture = false, hasGimbal = true,
            supportsZoom = true, zoom = CameraZoomProfile(stops = listOf(1.0, 2.0, 3.0, 6.0, 15.0)),
            nativeISO = CaptureNativeISOCapabilities(hop = false, ceiling = false),
            controls = mapOf(
                ControlFamily.ND_FILTER to SupportStatus.UNSUPPORTED,
                ControlFamily.FACE_METERING to SupportStatus.SUPPORTED,
                ControlFamily.EXPOSURE_COMPENSATION to SupportStatus.SUPPORTED,
                ControlFamily.RECORDING_FORMAT to SupportStatus.SUPPORTED,
                ControlFamily.CODEC_COLOR to SupportStatus.SUPPORTED,
                ControlFamily.PHOTO to SupportStatus.SUPPORTED,
                ControlFamily.MEDIA to SupportStatus.SUPPORTED,
                ControlFamily.MEDIA_DELETE to SupportStatus.SUPPORTED,
            ),
        )
        internal val INTEGRATION = IntegrationID("com.opencapture.insta360.luna")
        /** Official Video ISO wheel. */
        internal val ISO_VALUES = listOf(100, 160, 200, 400, 800, 1600, 3200, 6400)
        /** Official Video shutter wheel, slowest last. fw 1.1.15 adds 1/15 to 1/5. */
        internal val SHUTTER_DENOMINATORS = listOf(
            8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400, 320, 250,
            200, 160, 125, 100, 80, 60, 50, 40, 30, 25, 15, 10, 5,
        )

        private fun exposureProgram(exposure: LunaExposure): CameraExposureProgram? = when (exposure.program) {
            0L, 4L, 5L -> CameraExposureProgram.AUTOMATIC
            1L -> CameraExposureProgram.ISO_PRIORITY
            2L -> CameraExposureProgram.SHUTTER_PRIORITY
            3L -> CameraExposureProgram.MANUAL
            else -> null
        }

        internal fun iso(exposure: LunaExposure): ISOValue? {
            if (exposureProgram(exposure) == null) return null
            if (exposure.program !in setOf(1L, 3L)) return ISOValue.Auto
            if (exposure.iso !in 0..Int.MAX_VALUE.toLong()) return null
            return if (exposure.iso > 0) ISOValue.Manual(exposure.iso.toInt()) else ISOValue.Auto
        }

        internal fun shutter(exposure: LunaExposure): ShutterValue? {
            if (exposureProgram(exposure) == null) return null
            if (exposure.program !in setOf(2L, 3L) || exposure.shutterSeconds == 0.0) return ShutterValue.Auto
            return HostShutterAngle.readback(exposure.shutterSeconds)?.let(ShutterValue::Duration)
        }

        internal fun captureMode(mode: LunaShootingMode): CaptureMode {
            val (name, title) = when (mode) {
                LunaShootingMode.VIDEO -> "video" to "Video"
                LunaShootingMode.TIMELAPSE -> "timelapse" to "Timelapse"
                LunaShootingMode.TIME_SHIFT -> "timeshift" to "TimeShift"
                LunaShootingMode.SLOW_MOTION -> "slow-motion" to "Slow Motion"
                LunaShootingMode.PURE_VIDEO -> "purevideo" to "PureVideo"
                LunaShootingMode.PHOTO -> "photo" to "Photo"
                LunaShootingMode.PANO -> "pano" to "Pano"
            }
            val role = if (mode.isPhoto) CaptureMode.Role.PHOTO else CaptureMode.Role.VIDEO
            return CaptureMode(role, "${INTEGRATION.rawValue}.mode.$name", title)
        }

        /** Native recording content; a profile never declares the preview curve or its codec. */
        private fun recordingProfileLabel(color: Long): String? = when (color) {
            1L -> "Standard"
            2L -> "I-Log"
            3L -> "Vivid"
            4L -> "HDR"
            5L -> "Dolby Vision"
            else -> null
        }

        internal fun profileID(color: Long): String? =
            mapOf(1L to "standard", 2L to "i-log", 3L to "vivid", 4L to "hdr", 5L to "dolby-vision")[color]
                ?.let { "${INTEGRATION.rawValue}.profile.$it" }

        private fun volume(storage: LunaStorage, at: MonotonicInstant, remaining: Pair<Long, MonotonicInstant>? = null): StorageVolume {
            val media = when (storage.cardState) {
                0L -> MediaState.READY
                1L -> MediaState.ABSENT
                2L -> MediaState.FULL
                3L, 4L, 5L -> MediaState.ERROR
                else -> null
            }
            return StorageVolume(
                "location-${storage.location}",
                media = media?.let { ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, at) } ?: ObservedValue.unknown,
                // Free space only means something on a usable card.
                freeBytes = if (storage.isUsable) ObservedValue(storage.freeBytes, ObservationOrigin.CAMERA_REPORTED, at) else ObservedValue.unknown,
                totalBytes = if (storage.isUsable && storage.totalBytes > 0) ObservedValue(storage.totalBytes, ObservationOrigin.CAMERA_REPORTED, at) else ObservedValue.unknown,
                // Zero is a known full card; no entry for this location stays unknown.
                remainingRecordingTime = remaining?.takeIf { storage.isUsable && it.first >= 0 }
                    ?.let { (seconds, reported) -> ObservedValue(seconds.seconds, ObservationOrigin.CAMERA_REPORTED, reported) }
                    ?: ObservedValue.unknown,
            )
        }
    }
}
