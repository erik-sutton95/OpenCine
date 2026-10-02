package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CameraTimecode
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
import com.opencapture.opencine.core.SettingDescriptor
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingSemantics
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ShutterValue
import com.opencapture.opencine.core.StorageVolume
import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.core.UnavailableReason
import com.opencapture.opencine.core.WhiteBalanceValue
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

    private data class Awaiting(val intent: CameraCommandIntent, val acceptedAt: MonotonicInstant, val deadline: MonotonicInstant)

    override val id: CameraSessionID = CameraSessionID()
    private val lock = Any()
    private var current = CameraSnapshot(id, connection = ConnectionState.Connecting(ConnectionAttemptID(), ConnectionPhase.LINK))
    private val feed = MutableStateFlow(current)
    override val snapshots: StateFlow<CameraSnapshot> = feed.asStateFlow()

    /** Recording colour profile (option 35) as a namespaced id; camera-reported or unknown. */
    @Volatile var recordingProfile: ObservedValue<String> = ObservedValue.unknown
        private set

    private var shootingMode: LunaShootingMode? = null
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
            publish()
        }
    }

    internal fun ingest(device: LunaDeviceStatus) {
        synchronized(lock) {
            if (closed) return
            val at = now()
            device.shootingMode?.let {
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
                current = current.copy(storage = ObservedValue(volumes.map { volume(it, at) }, ObservationOrigin.CAMERA_REPORTED, at))
            }
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
            val still = settings.stillExposure.takeIf { carries(20) }
            val video = settings.videoExposure.takeIf { carries(21) }
            val exposure = if (shootingMode?.isPhoto == true) still ?: video else video ?: still
            val values = current.settings.toMutableMap()
            if (exposure != null) {
                values[SettingKey.ISO] = ObservedValue(SettingValue.Iso(iso(exposure)), ObservationOrigin.CAMERA_REPORTED, at)
                values[SettingKey.SHUTTER] = ObservedValue(SettingValue.Shutter(shutter(exposure)), ObservationOrigin.CAMERA_REPORTED, at)
                reportedAt[SettingKey.ISO] = at
                reportedAt[SettingKey.SHUTTER] = at
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
            if (carries(35)) {
                settings.colorMode?.let(::profileID)?.let { recordingProfile = ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, at) }
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
            current = current.copy(settings = values)
            refreshCapabilities()
            settle()
            publish()
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
            settle()
            publish()
        }
    }

    /**
     * Time of day the host derives for the live picture: the phone sets the camera clock and pins
     * frame stamps to its own, so the value is `CLOCK_DERIVED`, never a camera counter.
     */
    fun ingest(timecode: CameraTimecode) {
        synchronized(lock) {
            if (closed) return
            current = current.copy(timecode = ObservedValue(timecode, ObservationOrigin.CLOCK_DERIVED, now()))
            publish()
        }
    }

    /**
     * What a monitor lays out for this camera (Swift `layout(base:)`): the Core projection of the
     * snapshot plus the Luna gimbal ([MOTION]). [base] carries what Core has no vocabulary for yet.
     */
    fun layout(base: MonitorLayoutCapabilities = MonitorLayoutCapabilities()): MonitorLayoutCapabilities {
        val capabilities = synchronized(lock) { current.capabilities }
        return MonitorLayoutCapabilities(capabilities, MOTION, base)
    }

    // CameraSession.

    override suspend fun submit(command: CameraCommand): CommandReceipt {
        val operation = command.operation
        val key = command.intent.key
        val request: LunaControl.Request
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
            awaiting[operation] = Awaiting(command.intent, acceptedAt, deadline)
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

    private fun exposure(iso: ISOValue?, shutter: ShutterValue?, bank: Int): LunaControl.Request {
        val manualIso = (iso as? ISOValue.Manual)?.iso?.toLong()
        val seconds = (shutter as? ShutterValue.Duration)?.seconds?.doubleValue
        return LunaControl.videoExposure(LunaControl.exposureProgram(manualIso, seconds), manualIso, seconds, bank)
    }

    // Settling.

    private fun alreadyReported(intent: CameraCommandIntent) = when (intent) {
        CameraCommandIntent.StartRecording -> current.recording.value == RecordingState.RECORDING
        CameraCommandIntent.StopRecording -> current.recording.value == RecordingState.IDLE
        else -> false
    }

    private fun reportShows(intent: CameraCommandIntent) = when (intent) {
        is CameraCommandIntent.Set -> when (val target = intent.value) {
            is SettingValue.Zoom -> (current.value(SettingKey.ZOOM).value as? SettingValue.Zoom)?.let {
                abs(target.ratio - it.ratio) < 0.05
            } == true
            else -> current.value(target.key).value == target
        }
        CameraCommandIntent.StartRecording -> current.recording.value == RecordingState.RECORDING
        CameraCommandIntent.StopRecording -> current.recording.value == RecordingState.IDLE
        is CameraCommandIntent.FocusPoint -> false
    }

    /** Confirms what a readback shows; ends what its settle window has closed on. */
    private fun settle() {
        val at = now()
        for ((operation, write) in awaiting.toList()) {
            if (reportShows(write.intent)) {
                transition(operation, CommandStage.Confirmed)
            } else if (at >= write.deadline) {
                val heard = reportedAt[write.intent.key]?.let { it > write.acceptedAt } == true
                transition(operation, if (heard) CommandStage.Failed(CommandFailure.NOT_APPLIED) else CommandStage.TimedOut)
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

    private fun transition(operation: OperationID, stage: CommandStage): CommandReceipt {
        val receipt = receipts.getValue(operation)
        // A late completion never rewrites a finished outcome.
        if (receipt.isFinished) return receipt
        val next = receipt.copy(stage = stage)
        receipts[operation] = next
        if (next.isFinished) {
            awaiting.remove(operation)
            if (targets[next.intent.key]?.first == operation) targets.remove(next.intent.key)
            waiters.remove(operation)?.complete(next)
        }
        return next
    }

    private fun publish() {
        current = current.copy(revision = current.revision.next())
        feed.value = current
    }

    // Capabilities and mapping.

    private fun refreshCapabilities() {
        // A write carries ISO and shutter together, so neither is safe before both are known.
        val exposure = if (SettingKey.ISO in current.settings) Availability.Available else Availability.Unavailable(UnavailableReason.NotReady)
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
                SettingKey.SHUTTER, availability = exposure,
                domain = SettingDomain(
                    listOf<SettingValue>(SettingValue.Shutter(ShutterValue.Auto)) +
                        SHUTTER_DENOMINATORS.map { SettingValue.Shutter(ShutterValue.Duration(Rational(1, it))) },
                ),
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
        )
        zoomDomain?.let { descriptors += SettingDescriptor(SettingKey.ZOOM, domain = SettingDomain(range = it)) }
        // Timecode is host-derived time of day ([ingest]); Luna reports no audio levels.
        val declared = CapabilitySnapshot(
            current.capabilities.revision, descriptors,
            timecode = SupportStatus.SUPPORTED, audioLevels = SupportStatus.UNSUPPORTED,
        )
        if (declared == current.capabilities) return
        current = current.copy(capabilities = declared.copy(revision = declared.revision.next()))
    }

    companion object {
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
        internal val INTEGRATION = IntegrationID("com.opencapture.insta360.luna")
        /** Official Video ISO wheel. */
        internal val ISO_VALUES = listOf(100, 160, 200, 400, 800, 1600, 3200, 6400)
        /** Official Video shutter wheel, slowest last. fw 1.1.15 adds 1/15 to 1/5. */
        internal val SHUTTER_DENOMINATORS = listOf(
            8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400, 320, 250,
            200, 160, 125, 100, 80, 60, 50, 40, 30, 25, 15, 10, 5,
        )

        /** Programs 1 and 3 hold the reported ISO; the rest choose it. */
        internal fun iso(exposure: LunaExposure): ISOValue =
            if (exposure.program in setOf(1L, 3L) && exposure.iso > 0) ISOValue.Manual(exposure.iso.toInt()) else ISOValue.Auto

        /** Programs 2 and 3 hold the reported shutter; the rest choose it. */
        internal fun shutter(exposure: LunaExposure): ShutterValue =
            if (exposure.program in setOf(2L, 3L) && exposure.shutterSeconds > 0) {
                ShutterValue.Duration(Rational(1, (1 / exposure.shutterSeconds).roundToInt()))
            } else {
                ShutterValue.Auto
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

        internal fun profileID(color: Long): String? =
            mapOf(1L to "standard", 2L to "i-log", 3L to "vivid", 4L to "hdr", 5L to "dolby-vision")[color]
                ?.let { "${INTEGRATION.rawValue}.profile.$it" }

        private fun volume(storage: LunaStorage, at: MonotonicInstant): StorageVolume {
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
            )
        }
    }
}
