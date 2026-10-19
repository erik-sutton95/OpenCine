package com.opencapture.opencine.dji

import com.opencapture.opencine.core.AudioLevels
import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.media.HostShutterAngle
import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CameraTimecode
import com.opencapture.opencine.core.CapabilitySnapshot
import com.opencapture.opencine.core.CaptureMode
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.CommandReceipt
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionAttemptID
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.MonitorLayoutCapabilities
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservationPrecision
import com.opencapture.opencine.core.OperationID
import com.opencapture.opencine.core.PowerStatus
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.SettingDescriptor
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.StorageVolume
import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.core.TimecodeCapability
import com.opencapture.opencine.core.TimecodePrecision
import com.opencapture.opencine.core.UnavailableReason
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.opencine.core.rejection
import com.opencapture.opencine.motion.MonitorLayoutCapabilities
import com.opencapture.opencine.vocabulary.CamFov
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraModel
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.CaptureCodecColorChoices
import com.opencapture.opencine.vocabulary.ControlCapabilities
import com.opencapture.opencine.vocabulary.ConnectionPhase as PocketPhase
import com.opencapture.opencine.vocabulary.EvComp
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import com.opencapture.opencine.core.CameraSession as OpenCineCameraSession
import com.opencapture.opencine.core.ConnectionPhase as CorePhase

/** Wire progress of one camera SET, reported by `PocketCameraSession.fireKind` (iOS `ControlWireEvent`). */
enum class ControlWireEvent {
    /** Refused locally, or replaced by a newer request before it reached the wire. */
    NOT_SENT,
    SENT,

    /** The camera ACKed. Its status may not show the value yet. */
    ACKNOWLEDGED,

    /** The camera's own status shows the requested value. */
    CONFIRMED,

    /** NACK. */
    REFUSED,

    /** The settle window closed with no ACK and no matching status. */
    UNCONFIRMED,
}

/** Camera-reported white balance: Kelvin is 0 in Auto. */
data class ReportedWhiteBalance(val mode: Int, val kelvin: Int, val tint: Int)

/**
 * What the seam reads from the Pocket session. `isoIndex`, `whiteBalance` and `recording` are
 * camera reports only, never the optimistic HUD values in `PocketCameraSession.status`.
 */
data class PocketControlState(
    /** A SET can go on the wire now (the `fireKind` admission rule, lease included). */
    val linkReady: Boolean = false,
    val authorized: Boolean = true,
    val recovering: Boolean = false,
    val phase: PocketPhase = PocketPhase.IDLE,
    val cameraId: String? = null,
    val shootingMode: Int = -1,
    val busy: Boolean = false,
    /** Legal `0x02/0x2A` index bytes; `0` (Auto) only where the color mode offers it. */
    val isoChoices: List<Int> = emptyList(),
    val isoIndex: Int? = null,
    val whiteBalance: ReportedWhiteBalance? = null,
    /**
     * The white balance request in flight (iOS `pendingWhiteBalance`). DJI sends white balance
     * and tint in one frame, so the next white balance or tint frame is composed on it. It never
     * confirms anything.
     */
    val pendingWhiteBalance: ReportedWhiteBalance? = null,
    val recording: Boolean? = null,
    val batteryPercent: Int? = null,
    val storageFreeMb: Int? = null,
    /** The connected body; `null` while none is known. */
    val model: CameraModel? = null,
    /** `timecode_info` as decoded from the bytes; `null` until reported. */
    val timecode: CameraTimecode? = null,
    /** `cam_audio_status_v2` in dBFS; `null` until reported ([audioLevels]). */
    val audioLevels: AudioLevels? = null,
    val charging: Boolean? = null,
    val storage: com.opencapture.opencine.core.StorageStatus? = null,
    val storageTotalMb: Int? = null,
)

/** The Pocket session as the seam drives it. `PocketCameraSession` and the JVM tests implement it. */
interface PocketControlPort {
    val commandOwner: DjiCommandOwner? get() = null
    fun controlState(): PocketControlState
    fun captureControlState(): DjiCaptureControlState? = null
    fun writeShutter(denominator: Int, onStage: (ControlWireEvent) -> Unit) = onStage(ControlWireEvent.NOT_SENT)
    fun writeHostShutterAngle(degrees: Double, denominator: Int, admission: DjiCommandAdmission?, onStage: (ControlWireEvent) -> Unit) = onStage(ControlWireEvent.NOT_SENT)
    fun writeExposureCompensation(value: EvComp, onStage: (ControlWireEvent) -> Unit) = onStage(ControlWireEvent.NOT_SENT)
    fun writeFocusMode(continuous: Boolean, onStage: (ControlWireEvent) -> Unit) = onStage(ControlWireEvent.NOT_SENT)
    fun writeZoom(ratio: Double, onStage: (ControlWireEvent) -> Unit) = onStage(ControlWireEvent.NOT_SENT)

    fun setIsoIndex(index: Int, onStage: ((ControlWireEvent) -> Unit)? = null)

    fun setWhiteBalanceAuto(tint: Int? = null, onStage: ((ControlWireEvent) -> Unit)? = null)

    fun setWhiteBalance(kelvin: Int, tint: Int, onStage: ((ControlWireEvent) -> Unit)? = null)

    fun setRecording(start: Boolean, onStage: ((ControlWireEvent) -> Unit)? = null)

    fun takePhoto()

    // Supplied operations never fall through an unavailable native port into direct work.
    fun writeShutter(denominator: Int, admission: DjiCommandAdmission, onStage: (ControlWireEvent) -> Unit): Unit =
        onStage(ControlWireEvent.NOT_SENT)
    fun writeExposureCompensation(value: EvComp, admission: DjiCommandAdmission, onStage: (ControlWireEvent) -> Unit): Unit =
        onStage(ControlWireEvent.NOT_SENT)
    fun writeFocusMode(continuous: Boolean, admission: DjiCommandAdmission, onStage: (ControlWireEvent) -> Unit): Unit =
        onStage(ControlWireEvent.NOT_SENT)
    fun writeZoom(ratio: Double, admission: DjiCommandAdmission, onStage: (ControlWireEvent) -> Unit): Unit =
        onStage(ControlWireEvent.NOT_SENT)
    fun setIsoIndex(index: Int, admission: DjiCommandAdmission, onStage: ((ControlWireEvent) -> Unit)?): Unit {
        onStage?.invoke(ControlWireEvent.NOT_SENT)
    }
    fun setWhiteBalanceAuto(tint: Int?, admission: DjiCommandAdmission, onStage: ((ControlWireEvent) -> Unit)?): Unit {
        onStage?.invoke(ControlWireEvent.NOT_SENT)
    }
    fun setWhiteBalance(kelvin: Int, tint: Int, admission: DjiCommandAdmission, onStage: ((ControlWireEvent) -> Unit)?): Unit {
        onStage?.invoke(ControlWireEvent.NOT_SENT)
    }
    fun setRecording(start: Boolean, admission: DjiCommandAdmission, onStage: ((ControlWireEvent) -> Unit)?): Unit {
        onStage?.invoke(ControlWireEvent.NOT_SENT)
    }
    fun takePhoto(admission: DjiCommandAdmission): Unit {}

    fun noteControlRejection(note: String)
}

/**
 * OpenCineCore `CameraSession` over the Pocket session for the CORE-02 slice: ISO, white balance
 * and record start/stop (iOS `DJICameraSessionAdapter`). One per `PocketCameraSession`; the
 * control epoch advances whenever the datalink is replaced. Confined to the main thread like
 * the session; [scope] runs only the timeouts.
 */
class DjiCameraSessionAdapter(
    private val port: PocketControlPort,
    private val scope: CoroutineScope,
    private val onClose: ((SessionCloseReason) -> Unit)?,
    private val clock: () -> MonotonicInstant = { MonotonicInstant.now() },
) : OpenCineCameraSession {
    /** Retain the original constructor and its trailing clock lambda. */
    constructor(
        port: PocketControlPort,
        scope: CoroutineScope,
        clock: () -> MonotonicInstant = { MonotonicInstant.now() },
    ) : this(port, scope, null, clock)

    override val id: CameraSessionID = CameraSessionID()

    /** ACK to camera-reported value. Record telemetry trails its ACK by about 1 s. */
    // ponytail: hand-picked; tune against Pocket 3 / Pocket 4 record telemetry on hardware.
    var readbackTimeout: Duration = 3.seconds

    /** Admission to ACK or settle: coalesce hold plus the session's 2 s settle window. */
    var wireTimeout: Duration = 4.seconds

    private val _snapshots = MutableStateFlow(CameraSnapshot(session = id, epoch = ControlEpoch(1)))
    private val followed = _snapshots.asStateFlow()

    /**
     * Nothing rebuilds while nobody follows, so a new follower starts from the session as it is
     * now (Swift `snapshots()` starts from `current`), not from a placeholder.
     */
    override val snapshots: StateFlow<CameraSnapshot>
        get() {
            rebuild()
            return followed
        }

    private var epoch = ControlEpoch(1)
    private var attempt = ConnectionAttemptID()
    private var closed = false

    // ponytail: receipts live as long as the session (Core contract); prune finished ones if a
    // long shoot ever makes this measurable.
    private val receipts = HashMap<OperationID, CommandReceipt>()
    private val open = HashMap<OperationID, Expectation>()
    private val waiters = HashMap<OperationID, CompletableDeferred<CommandReceipt>>()

    private class Expectation(
        var deadline: MonotonicInstant, val shows: (PocketControlState) -> Boolean,
        val permitsReportBeforeAck: Boolean = false,
    )

    /** A snapshot rebuilt from the session right now. */
    val current: CameraSnapshot
        get() {
            rebuild()
            return _snapshots.value
        }

    // ---- UI entry points ----

    fun request(intent: CameraCommandIntent): CommandReceipt =
        send(CameraCommand(intent, CommandPreconditions(current)))

    fun setIsoIndex(index: Int): CommandReceipt =
        request(CameraCommandIntent.Set(SettingValue.Iso(iso(index))))

    public fun setIsoIndex(index: Int, admission: DjiCommandAdmission): CommandReceipt =
        request(CameraCommandIntent.Set(SettingValue.Iso(iso(index))), admission)

    /** `null` keeps the current (or pending) tint, as the Auto row always has. */
    fun setWhiteBalanceAuto(tint: Int? = null): CommandReceipt = setWhiteBalance(WhiteBalanceValue.Auto, tint)

    public fun setWhiteBalanceAuto(tint: Int? = null, admission: DjiCommandAdmission): CommandReceipt =
        setWhiteBalance(WhiteBalanceValue.Auto, tint, admission)

    /** Kelvin snaps to the 100 K steps the camera stores (`K/100` on the wire). */
    fun setWhiteBalanceCustom(kelvin: Int, tint: Int): CommandReceipt =
        setWhiteBalance(WhiteBalanceValue.Kelvin((kelvin.coerceIn(2_000, 10_000) + 50) / 100 * 100), tint)

    public fun setWhiteBalanceCustom(kelvin: Int, tint: Int, admission: DjiCommandAdmission): CommandReceipt =
        setWhiteBalance(WhiteBalanceValue.Kelvin((kelvin.coerceIn(2_000, 10_000) + 50) / 100 * 100), tint, admission)

    /**
     * One Core write per setting that changes: white balance (keeping the pending tint), then tint
     * (on the pending white balance). Returns the last receipt.
     */
    private fun setWhiteBalance(value: WhiteBalanceValue, tint: Int?): CommandReceipt =
        setWhiteBalance(value, tint, null)

    private fun setWhiteBalance(value: WhiteBalanceValue, tint: Int?, admission: DjiCommandAdmission?): CommandReceipt {
        fun write(value: SettingValue): CommandReceipt = if (admission == null) {
            request(CameraCommandIntent.Set(value))
        } else {
            request(CameraCommandIntent.Set(value), admission)
        }
        val state = port.controlState()
        val pending = state.pendingWhiteBalance ?: state.whiteBalance
        val t = tint?.coerceIn(-100, 100)
        if (t == null || t == pending?.tint) return write(SettingValue.WhiteBalance(value))
        if (pending?.let { whiteBalance(it) } != value) write(SettingValue.WhiteBalance(value))
        return write(SettingValue.WhiteBalanceTint(t.toDouble()))
    }

    /**
     * Rec lamp: Photo fires a still; video resolves to an explicit start or stop from a fresh
     * snapshot, never a blind toggle (plan 5.4).
     */
    fun shutter(): CommandReceipt? {
        if (CameraCommands.isPhotoMode(port.controlState().shootingMode)) {
            port.takePhoto()
            return null
        }
        val recording = current.recording.value == RecordingState.RECORDING
        return request(if (recording) CameraCommandIntent.StopRecording else CameraCommandIntent.StartRecording)
    }
    public fun shutter(admission: DjiCommandAdmission): CommandReceipt? {
        if (!admission.admits(port.commandOwner)) return null
        if (CameraCommands.isPhotoMode(port.controlState().shootingMode)) {
            port.takePhoto(admission)
            return null
        }
        val recording = current.recording.value == RecordingState.RECORDING
        return request(if (recording) CameraCommandIntent.StopRecording else CameraCommandIntent.StartRecording, admission)
    }

    override fun receipt(operation: OperationID): CommandReceipt? = receipts[operation]

    /**
     * The one control model for the connected body (Swift `controlCapabilities(codecColor:)`): its
     * declared profile and motion merged with the live capabilities. [codecColor] is what the codec
     * and colour popup lists now, when the host has it.
     */
    fun controlCapabilities(codecColor: CaptureCodecColorChoices? = null): ControlCapabilities {
        val model = port.controlState().model
        return ControlCapabilities.derive(current.capabilities, model?.captureProfile, model?.motion, codecColor)
    }

    /**
     * What a monitor lays out for the connected body (Swift `layout(base:)`): the Core projection
     * of [current] plus the body's motion ([CameraModel.motion]). [base] carries what Core has no
     * vocabulary for yet. With no body known, motion stays unknown and the Core projection keeps
     * [base].
     */
    fun layout(base: MonitorLayoutCapabilities = MonitorLayoutCapabilities()): MonitorLayoutCapabilities {
        val capabilities = current.capabilities
        val model = port.controlState().model ?: return MonitorLayoutCapabilities(capabilities, base)
        var layout = MonitorLayoutCapabilities(capabilities, model.motion, base)
        if (port.captureControlState() == null) {
            // Compatibility for callers that have not supplied the additive capture port.
            layout = layout.copy(zoom = model.supportsZoom, focus = model.supportsFocusMode)
        }
        // Variable iris strategy remains a typed panel, not a common f-number edit.
        return layout.copy(iris = model.supportsAperture)
    }

    // ---- session hooks ----

    /** Status, phase or busy changed. Cheap unless someone collects or a request awaits readback. */
    fun sessionDidChange() {
        if (closed) return
        if (_snapshots.subscriptionCount.value > 0) rebuild()
        if (open.isEmpty()) return
        val state = port.controlState()
        for ((operation, expectation) in open.toList()) {
            if ((receipts[operation]?.stage == CommandStage.AwaitingObservation ||
                (expectation.permitsReportBeforeAck && receipts[operation]?.stage == CommandStage.Sent)) &&
                expectation.shows(state)) {
                finish(operation, CommandStage.Confirmed)
            }
        }
    }

    /** The datalink was replaced or dropped. Requests on the old link cannot be followed. */
    fun linkDidChange() {
        if (closed) return
        epoch = epoch.next()
        for (operation in open.keys.toList()) abandon(operation)
        if (_snapshots.subscriptionCount.value > 0) rebuild()
    }

    // ---- OpenCineCore.CameraSession ----

    override suspend fun submit(command: CameraCommand): CommandReceipt = send(command)
    public suspend fun submit(command: CameraCommand, admission: DjiCommandAdmission): CommandReceipt =
        sendAdmitted(command, admission)

    override suspend fun outcome(operation: OperationID): CommandReceipt? {
        val receipt = receipts[operation] ?: return null
        if (receipt.isFinished) return receipt
        return waiters.getOrPut(operation) { CompletableDeferred() }.await()
    }

    override suspend fun close(reason: SessionCloseReason): Unit = closeNow(reason)

    /** Retires this seam, then calls its optional connection owner once; never sends a command. */
    override fun closeNow(reason: SessionCloseReason) {
        if (closed) return
        for (operation in open.keys.toList()) abandon(operation)
        closed = true
        val last = _snapshots.value
        _snapshots.value =
            last.copy(
                connection = ConnectionState.Disconnected(reason),
                authority = ControlAuthority.Unavailable(UnavailableReason.Link),
                revision = last.revision.next(),
            )
        onClose?.invoke(reason)
    }

    // ---- commands ----

    fun send(command: CameraCommand): CommandReceipt = sendAdmitted(command, null)

    public fun request(intent: CameraCommandIntent, admission: DjiCommandAdmission): CommandReceipt =
        sendAdmitted(CameraCommand(intent, CommandPreconditions(current)), admission)

    private fun sendAdmitted(command: CameraCommand, admission: DjiCommandAdmission?): CommandReceipt {
        val operation = command.operation
        receipts[operation]?.let { return it }
        val snapshot = current
        receipts[operation] =
            CommandReceipt(
                operation, id, command.intent,
                confirmation = snapshot.capabilities[command.intent.key]?.semantics?.confirmation
                    ?: com.opencapture.opencine.core.SettingSemantics.Confirmation.READBACK,
            )
        if (admission != null && !admission.admits(port.commandOwner)) {
            return advance(operation, CommandStage.Rejected(CommandRejection.AuthorityExpired))
        }
        val rejection = snapshot.rejection(command, clock()) ?: integrationRejection(command.intent, snapshot)
        if (rejection != null) {
            noteRejection(rejection)
            return advance(operation, CommandStage.Rejected(rejection))
        }
        advance(operation, CommandStage.Admitted)
        if (alreadyReported(command.intent, snapshot)) return advance(operation, CommandStage.Confirmed)
        val plan = wirePlan(command.intent, admission)
            ?: return advance(operation, CommandStage.Rejected(CommandRejection.Unsupported))
        open[operation] = Expectation(clock() + wireTimeout, plan.shows, plan.requiresReport)
        expire(wireTimeout)
        plan.fire { event ->
            handle(if (plan.requiresReport && event == ControlWireEvent.CONFIRMED)
                ControlWireEvent.ACKNOWLEDGED else event, operation)
        }
        return receipts.getValue(operation)
    }

    private class WirePlan(
        val shows: (PocketControlState) -> Boolean,
        val requiresReport: Boolean = false,
        val fire: ((ControlWireEvent) -> Unit) -> Unit,
    )

    /**
     * Common intent to the DUML call that carries it, plus what the camera must report after. DJI
     * sends white balance and tint in one frame, so each write fills the other half from the
     * pending (else reported) white balance.
     */
    private fun wirePlan(intent: CameraCommandIntent, admission: DjiCommandAdmission?): WirePlan? =
        when (intent) {
            is CameraCommandIntent.Set ->
                when (val value = intent.value) {
                    is SettingValue.Shutter -> {
                        when (val shutter = value.value) {
                            is com.opencapture.opencine.core.ShutterValue.Duration -> {
                                val duration = shutter.seconds
                                if (duration.numerator != 1 || duration.denominator <= 0) null
                                else WirePlan({ port.captureControlState()?.reported?.shutterDenom == duration.denominator }, true) {
                                    if (admission == null) port.writeShutter(duration.denominator, it)
                                    else port.writeShutter(duration.denominator, admission, it)
                                }
                            }
                            is com.opencapture.opencine.core.ShutterValue.Angle -> {
                                val state = port.captureControlState()?.takeIf { it.emulatesShutterAngle }
                                val denominator = state?.let { HostShutterAngle.denominator(shutter.degrees,
                                    it.reported.fps.takeIf { rate -> rate > 0 }?.toDouble(), it.offeredShutterDenoms) }
                                denominator?.let { target -> WirePlan({ port.captureControlState()?.reported?.shutterDenom == target }, true) {
                                    port.writeHostShutterAngle(shutter.degrees, target, admission, it)
                                } }
                            }
                            com.opencapture.opencine.core.ShutterValue.Auto -> null
                        }
                    }
                    is SettingValue.ExposureCompensation -> EvComp.allCases.firstOrNull {
                        com.opencapture.opencine.core.Rational(it.thirds, 3) == value.stops
                    }?.let { target ->
                        WirePlan({ port.captureControlState()?.reported?.evComp == target.rawValue }, true) {
                            if (admission == null) port.writeExposureCompensation(target, it)
                            else port.writeExposureCompensation(target, admission, it)
                        }
                    }
                    is SettingValue.FocusMode -> {
                        val continuous = when (value.mode) {
                            com.opencapture.opencine.core.FocusMode.SINGLE -> false
                            com.opencapture.opencine.core.FocusMode.CONTINUOUS -> true
                            com.opencapture.opencine.core.FocusMode.MANUAL -> null
                        }
                        if (continuous == null) null else WirePlan({
                            port.captureControlState()?.reported?.focusMode ==
                                if (continuous) CameraCommands.FOCUS_CONTINUOUS else CameraCommands.FOCUS_SINGLE
                        }, true) {
                            if (admission == null) port.writeFocusMode(continuous, it)
                            else port.writeFocusMode(continuous, admission, it)
                        }
                    }
                    is SettingValue.Zoom -> WirePlan({
                        port.captureControlState()?.reported?.zoomFactor?.let { CamFov.matches(it, value.ratio) } ?: false
                    }, true) {
                        if (admission == null) port.writeZoom(value.ratio, it) else port.writeZoom(value.ratio, admission, it)
                    }
                    is SettingValue.Iso -> isoIndex(value.value)?.let { index ->
                        WirePlan({ it.isoIndex == index }) { onStage ->
                            if (admission == null) port.setIsoIndex(index, onStage) else port.setIsoIndex(index, admission, onStage)
                        }
                    }
                    is SettingValue.WhiteBalanceTint -> {
                        val state = port.controlState()
                        (state.pendingWhiteBalance ?: state.whiteBalance)?.let {
                            whiteBalancePlan(whiteBalance(it), value.tint.toInt(), admission)
                        }
                    }
                    is SettingValue.WhiteBalance -> {
                        val state = port.controlState()
                        whiteBalancePlan(value.value, (state.pendingWhiteBalance ?: state.whiteBalance)?.tint ?: 0, admission)
                    }
                    else -> null
                }
            CameraCommandIntent.StartRecording, CameraCommandIntent.StopRecording -> {
                val start = intent == CameraCommandIntent.StartRecording
                WirePlan({ it.recording == start }) { onStage ->
                    if (admission == null) port.setRecording(start, onStage) else port.setRecording(start, admission, onStage)
                }
            }
            is CameraCommandIntent.FocusPoint -> null
        }

    private fun whiteBalancePlan(value: WhiteBalanceValue, tint: Int, admission: DjiCommandAdmission?): WirePlan? {
        val t = tint.coerceIn(-100, 100)
        return when (val wb = value) {
            WhiteBalanceValue.Auto -> {
                val target = ReportedWhiteBalance(CameraCommands.WB_AUTO, 0, t)
                WirePlan({ it.whiteBalance == target }) { onStage ->
                    if (admission == null) port.setWhiteBalanceAuto(t, onStage) else port.setWhiteBalanceAuto(t, admission, onStage)
                }
            }
            is WhiteBalanceValue.Kelvin -> {
                val k = wb.kelvin.coerceIn(2_000, 10_000)
                val target = ReportedWhiteBalance(CameraCommands.WB_CUSTOM, k, t)
                WirePlan({ it.whiteBalance == target }) { onStage ->
                    if (admission == null) port.setWhiteBalance(k, t, onStage) else port.setWhiteBalance(k, t, admission, onStage)
                }
            }
            is WhiteBalanceValue.Preset -> null
        }
    }

    private fun handle(event: ControlWireEvent, operation: OperationID) {
        // A finished receipt is final: a late ACK never rewrites an outcome.
        val expectation = open[operation] ?: return
        when (event) {
            ControlWireEvent.NOT_SENT -> finish(operation, CommandStage.Failed(CommandFailure.NOT_SENT))
            ControlWireEvent.SENT -> advance(operation, CommandStage.Sent)
            ControlWireEvent.ACKNOWLEDGED -> {
                advance(operation, CommandStage.Accepted)
                if (expectation.shows(port.controlState())) {
                    finish(operation, CommandStage.Confirmed)
                } else {
                    advance(operation, CommandStage.AwaitingObservation)
                    expectation.deadline = clock() + readbackTimeout
                    expire(readbackTimeout)
                }
            }
            // Only the camera-reported values decide, whoever claims the match.
            ControlWireEvent.CONFIRMED ->
                finish(
                    operation,
                    if (expectation.shows(port.controlState())) CommandStage.Confirmed else CommandStage.TimedOut,
                )
            ControlWireEvent.REFUSED -> finish(operation, CommandStage.Rejected(CommandRejection.CameraRefused))
            ControlWireEvent.UNCONFIRMED -> finish(operation, CommandStage.TimedOut)
        }
    }

    private fun noteRejection(rejection: CommandRejection) {
        when (rejection) {
            CommandRejection.SessionClosed, CommandRejection.WrongSession, CommandRejection.NotConnected,
            CommandRejection.StaleEpoch, CommandRejection.NoAuthority,
            -> port.noteControlRejection("not live")
            CommandRejection.RecordingStateUnknown -> port.noteControlRejection("Waiting for the camera's record state")
            else -> Unit
        }
    }

    private fun expire(after: Duration) {
        scope.launch {
            delay(after)
            expireOverdue()
        }
    }

    private fun expireOverdue() {
        val now = clock()
        for ((operation, expectation) in open.toList()) {
            if (expectation.deadline > now) continue
            if (receipts[operation]?.stage == CommandStage.AwaitingObservation) {
                finish(operation, CommandStage.TimedOut)
            } else {
                abandon(operation)
            }
        }
    }

    /** Unsent work fails; sent work may have reached the camera, so its outcome is unknown. */
    private fun abandon(operation: OperationID) {
        when (receipts[operation]?.stage) {
            CommandStage.Created, CommandStage.Admitted ->
                finish(operation, CommandStage.Failed(CommandFailure.NOT_SENT))
            else -> finish(operation, CommandStage.OutcomeUnknown)
        }
    }

    private fun finish(operation: OperationID, stage: CommandStage): CommandReceipt {
        open.remove(operation)
        return advance(operation, stage)
    }

    private fun advance(operation: OperationID, stage: CommandStage): CommandReceipt {
        val receipt = receipts.getValue(operation).copy(stage = stage)
        receipts[operation] = receipt
        if (receipt.isFinished) waiters.remove(operation)?.complete(receipt)
        return receipt
    }

    // ---- snapshot mapping (raw DJI state to common values) ----

    private fun rebuild() {
        if (closed) return
        val state = port.controlState()
        val last = _snapshots.value
        val connection = connection(state, last.connection)
        val declared = CapabilitySnapshot(
            revision = last.capabilities.revision, descriptors = descriptors(state) + (port.captureControlState()?.descriptors ?: emptyList()),
            timecodeCapability = timecodeCapability(state.model), audioLevels = audioLevelsSupport(state.model),
        )
        val capabilities =
            if (declared == last.capabilities) last.capabilities else declared.copy(revision = declared.revision.next())
        val next =
            last.copy(
                epoch = epoch,
                device = state.cameraId?.let { CameraDeviceID.durable(it, INTEGRATION) },
                connection = connection,
                authority = when {
                    connection != ConnectionState.Ready -> ControlAuthority.Unavailable(UnavailableReason.Link)
                    state.authorized -> ControlAuthority.Owner
                    else -> ControlAuthority.Unavailable(UnavailableReason.Authority)
                },
                capabilities = capabilities,
                mode = mode(state.shootingMode),
                settings = settings(state) + (port.captureControlState()?.settings ?: emptyMap()),
                recordingFormat = DjiRecordingObservations.recording(port.captureControlState()?.reported,
                    state.model?.captureProfile?.labels ?: com.opencapture.opencine.vocabulary.CameraLabelProfile.standard),
                exposureProgram = DjiRecordingObservations.exposureProgram(port.captureControlState()?.reported),
                recording = state.recording?.let {
                    ObservedValue(if (it) RecordingState.RECORDING else RecordingState.IDLE, ObservationOrigin.CAMERA_REPORTED, null)
                } ?: ObservedValue.unknown,
                power = PowerStatus(
                    battery = state.batteryPercent?.let { ObservedValue(
                        it / 100.0, ObservationOrigin.CAMERA_REPORTED, null,
                        precision = ObservationPrecision.Quantized(0.01)) } ?: ObservedValue.unknown,
                    charging = (state.charging ?: port.captureControlState()?.reported?.chargingReading)?.let { ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, null) } ?: ObservedValue.unknown,
                ),
                storage = state.storage ?: state.storageFreeMb?.takeIf { it >= 0 }?.let {
                    val free = ObservedValue(it.toLong() * 1_048_576L, ObservationOrigin.CAMERA_REPORTED, null)
                    ObservedValue(listOf(StorageVolume("active", freeBytes = free,
                        totalBytes = state.storageTotalMb?.takeIf { it > 0 }?.let { ObservedValue(it.toLong() * 1_048_576, ObservationOrigin.CAMERA_REPORTED, null) } ?: ObservedValue.unknown)), ObservationOrigin.CAMERA_REPORTED, null)
                } ?: ObservedValue.unknown,
                timecode = state.timecode?.let { ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, null) }
                    ?: ObservedValue.unknown,
                audioLevels = state.audioLevels?.let { ObservedValue(it, ObservationOrigin.CAMERA_REPORTED, null) }
                    ?: ObservedValue.unknown,
            )
        if (next == last) return
        _snapshots.value = next.copy(revision = last.revision.next())
    }

    private fun connection(state: PocketControlState, last: ConnectionState): ConnectionState {
        if (state.linkReady) return ConnectionState.Ready
        if (last !is ConnectionState.Connecting && last !is ConnectionState.Recovering) attempt = ConnectionAttemptID()
        if (state.recovering) return ConnectionState.Recovering(attempt)
        return when (state.phase) {
            PocketPhase.SCANNING, PocketPhase.CONNECTING_GATT, PocketPhase.PAIRING, PocketPhase.READING_WIFI_CREDS ->
                ConnectionState.Connecting(attempt, CorePhase.LINK)
            PocketPhase.AWAITING_APPROVAL -> ConnectionState.Connecting(attempt, CorePhase.AWAITING_APPROVAL)
            PocketPhase.JOINING_WIFI -> ConnectionState.Connecting(attempt, CorePhase.JOINING_NETWORK)
            PocketPhase.OPENING_DATALINK -> ConnectionState.Connecting(attempt, CorePhase.NEGOTIATING)
            // Core has no "open but not linked" state; this session object outlives links.
            PocketPhase.IDLE, PocketPhase.LIVE, PocketPhase.FAILED -> ConnectionState.Discovered
        }
    }

    /** Declared support is exactly what [wirePlan] routes. A JVM test holds the two together. */
    private fun descriptors(state: PocketControlState): List<SettingDescriptor> {
        val recording: Availability =
            when {
                CameraCommands.isPhotoMode(state.shootingMode) -> Availability.Unavailable(UnavailableReason.Mode)
                state.busy -> Availability.Unavailable(UnavailableReason.Busy)
                else -> Availability.Available
            }
        return listOf(
            SettingDescriptor(
                SettingKey.ISO,
                domain = SettingDomain(choices = state.isoChoices.map { SettingValue.Iso(iso(it)) }.distinct()),
            ),
            SettingDescriptor(
                SettingKey.WHITE_BALANCE,
                domain = SettingDomain(
                    choices = listOf(SettingValue.WhiteBalance(WhiteBalanceValue.Auto)),
                    range = 2_000.0..10_000.0,
                    step = 100.0,
                ),
            ),
            // Tint rides on the white balance frame, so it needs a known white balance.
            SettingDescriptor(
                SettingKey.WHITE_BALANCE_TINT,
                domain = SettingDomain(range = -100.0..100.0, step = 1.0),
                availability = if (state.whiteBalance == null) {
                    Availability.Unavailable(UnavailableReason.OtherSetting(SettingKey.WHITE_BALANCE))
                } else {
                    Availability.Available
                },
            ),
            SettingDescriptor(SettingKey.RECORDING, availability = recording),
        )
    }

    private fun settings(state: PocketControlState): Map<SettingKey, ObservedValue<SettingValue>> =
        buildMap {
            state.isoIndex?.let {
                put(SettingKey.ISO, ObservedValue(SettingValue.Iso(iso(it)), ObservationOrigin.CAMERA_REPORTED, null))
            }
            state.whiteBalance?.let {
                put(SettingKey.WHITE_BALANCE, ObservedValue(SettingValue.WhiteBalance(whiteBalance(it)), ObservationOrigin.CAMERA_REPORTED, null))
                put(
                    SettingKey.WHITE_BALANCE_TINT,
                    ObservedValue(SettingValue.WhiteBalanceTint(it.tint.toDouble()), ObservationOrigin.CAMERA_REPORTED, null),
                )
            }
        }

    companion object {
        val INTEGRATION: IntegrationID = IntegrationID("org.opencapture.openpocketcine.dji")

        fun whiteBalance(wb: ReportedWhiteBalance): WhiteBalanceValue =
            if (wb.mode == CameraCommands.WB_CUSTOM) WhiteBalanceValue.Kelvin(wb.kelvin) else WhiteBalanceValue.Auto

        /**
         * Every body reports `timecode_info` except Nano, whose live and Multi View readouts never
         * showed one. Unknown body: unknown. Declared in whole seconds: the frame field rides the
         * throttled status push and is not proven to count per frame (A5 runtime check).
         */
        @Deprecated("Use timecodeCapability for declared precision")
        fun timecodeSupport(model: CameraModel?): SupportStatus = timecodeCapability(model).support

        fun timecodeCapability(model: CameraModel?): TimecodeCapability = when {
            model == null -> TimecodeCapability.unknown
            model.family == "nano" -> TimecodeCapability.unsupported
            else -> TimecodeCapability.supported(TimecodePrecision.Seconds)
        }

        /** The legacy frame-complete parser; a partial clock has no representable frame count. */
        @Deprecated("Use CameraStatus.timecodeReading for source precision")
        fun timecode(raw: String?): CameraTimecode? {
            val parts = raw?.split(':')?.mapNotNull(String::toIntOrNull)?.takeIf { it.size == 4 } ?: return null
            return CameraTimecode(parts[0], parts[1], parts[2], parts[3])
        }

        /** `cam_audio_status_v2` levels. Unknown body: unknown. */
        // ponytail: every body the app connects to has always shown the meter; narrow this per
        // body once one is captured without `cam_audio_status_v2`.
        fun audioLevelsSupport(model: CameraModel?): SupportStatus =
            if (model == null) SupportStatus.UNKNOWN else SupportStatus.SUPPORTED

        /** The camera-held meter in dBFS, `null` until `cam_audio_status_v2` arrives. */
        fun audioLevels(status: CameraStatus): AudioLevels? =
            if (!status.audioMetersReported) {
                null
            } else {
                AudioLevels(
                    AudioLevels.Channel(status.audioMetersLeft, status.audioPeakLeft),
                    AudioLevels.Channel(status.audioMetersRight, status.audioPeakRight),
                )
            }

        fun iso(index: Int): ISOValue =
            CameraCommands.isoValue(CameraCommands.djiIsoIndex(index))?.let { ISOValue.Manual(it) } ?: ISOValue.Auto

        fun isoIndex(value: ISOValue): Int? =
            when (value) {
                ISOValue.Auto -> 0
                // The DJI ladder only: ISO 160 has no DJI byte (I-2).
                is ISOValue.Manual -> CameraCommands.isoIndexFromValue(value.iso)?.takeIf { it in CameraCommands.ISO_INDEX_ALL }
                is ISOValue.AutoLimited -> null
            }

        private fun mode(raw: Int): ObservedValue<CaptureMode> {
            if (raw < 0) return ObservedValue.unknown
            val role = if (CameraCommands.isPhotoMode(raw)) CaptureMode.Role.PHOTO else CaptureMode.Role.VIDEO
            return ObservedValue(
                CaptureMode(role, "${INTEGRATION.rawValue}.mode.$raw", "Mode $raw"),
                ObservationOrigin.CAMERA_REPORTED, null,
            )
        }

        /**
         * The DJI record frames are value-shaped (`0x02/0x02` 01/00) but the app has only sent
         * them as a toggle of the reported state; a start while already recording is not
         * hardware-qualified. Unknown state is refused.
         */
        private fun integrationRejection(intent: CameraCommandIntent, snapshot: CameraSnapshot): CommandRejection? =
            when (intent) {
                CameraCommandIntent.StartRecording, CameraCommandIntent.StopRecording ->
                    if (snapshot.recording.isKnown) null else CommandRejection.RecordingStateUnknown
                else -> null
            }

        /** Idempotency: start while recording (or stop while idle) finishes without the wire. */
        private fun alreadyReported(intent: CameraCommandIntent, snapshot: CameraSnapshot): Boolean =
            when (intent) {
                CameraCommandIntent.StartRecording -> snapshot.recording.value == RecordingState.RECORDING
                CameraCommandIntent.StopRecording -> snapshot.recording.value == RecordingState.IDLE
                else -> false
            }
    }
}
