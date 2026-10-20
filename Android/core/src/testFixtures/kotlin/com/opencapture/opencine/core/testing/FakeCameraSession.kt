package com.opencapture.opencine.core.testing

import com.opencapture.opencine.core.AudioLevels
import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CameraTimecode
import com.opencapture.opencine.core.CameraTimecodeReading
import com.opencapture.opencine.core.CapabilitySnapshot
import com.opencapture.opencine.core.CaptureMode
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandReceipt
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionAttemptID
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.MediaState
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservationOrigin.CAMERA_REPORTED
import com.opencapture.opencine.core.ObservationPrecision
import com.opencapture.opencine.core.OperationID
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.SettingDescriptor
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingSemantics
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.StorageVolume
import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.core.TimecodeCapability
import com.opencapture.opencine.core.UnavailableReason
import com.opencapture.opencine.core.rejection
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.time.Duration

/** One mode the fake camera can be in: its common identity and the descriptors it exposes. */
@ConsistentCopyVisibility
public data class FakeMode private constructor(
    public val mode: CaptureMode,
    public val descriptors: List<SettingDescriptor>,
    public val unsupported: Set<SettingKey>,
    public val timecode: SupportStatus,
    public val audioLevels: SupportStatus,
    public val timecodeCapability: TimecodeCapability,
) {
    /** The published constructor retains its parameter order and value types. */
    public constructor(
        mode: CaptureMode,
        descriptors: List<SettingDescriptor>,
        unsupported: Set<SettingKey>,
        timecode: SupportStatus = SupportStatus.UNKNOWN,
        audioLevels: SupportStatus = SupportStatus.UNKNOWN,
    ) : this(mode, descriptors, unsupported, timecode, audioLevels, TimecodeCapability(timecode))

    /** Copy the published fields without losing an unchanged precision-rich reading. */
    public fun copy(
        mode: CaptureMode = this.mode,
        descriptors: List<SettingDescriptor> = this.descriptors,
        unsupported: Set<SettingKey> = this.unsupported,
        timecode: SupportStatus = this.timecode,
        audioLevels: SupportStatus = this.audioLevels,
    ): FakeMode = FakeMode(mode, descriptors, unsupported, timecode, audioLevels,
        if (timecode == this.timecode) timecodeCapability else TimecodeCapability(timecode))

    /** Replace the precise value, projecting the legacy field only when representable. */
    public fun withTimecodeCapability(value: TimecodeCapability): FakeMode =
        FakeMode(mode, descriptors, unsupported, value.support, audioLevels, value)

    public constructor(
        mode: CaptureMode, descriptors: List<SettingDescriptor>, unsupported: Set<SettingKey>,
        timecodeCapability: TimecodeCapability, audioLevels: SupportStatus = SupportStatus.UNKNOWN,
    ) : this(mode, descriptors, unsupported, timecodeCapability.support, audioLevels, timecodeCapability)
}

/** Behavior knobs. Each fixture family is one combination; shared tests never ask which. */
public data class FakeCameraBehavior(
    public val integration: IntegrationID,
    /** Time from an accepted write until the camera reports the result. */
    public val reportDelay: Duration,
    /** How long an operation waits for its observation when it has no earlier deadline. */
    public val observationTimeout: Duration,
    public val recordWire: RecordWire,
    /** Recording stays unavailable until the camera's own live view runs. */
    public val recordNeedsLiveView: Boolean = false,
    /**
     * Raw wire mode to common mode (the adapter-owned mapping). An unmapped raw mode is reported
     * as an OTHER mode with unknown capabilities.
     */
    public val modes: Map<Int, FakeMode>,
    /** `CLOCK_DERIVED` for a camera whose time of day the integration derives from a clock. */
    public val timecodeOrigin: ObservationOrigin = ObservationOrigin.CAMERA_REPORTED,
) {
    public enum class RecordWire {
        /** One wire command flips recording, so it is only safe with a known reported state. */
        TOGGLE,
        EXPLICIT,
    }
}

/** The simulated camera's true state. The session learns it only through reports. */
@ConsistentCopyVisibility
public data class FakeDevice private constructor(
    public val rawMode: Int,
    public val settings: Map<SettingKey, SettingValue>,
    public val recording: Boolean?,
    public val batteryPercent: Int?,
    public val freeBytes: Long?,
    public val timecode: CameraTimecode?,
    public val audioLevels: AudioLevels?,
    public val timecodeReading: CameraTimecodeReading?,
) {
    /** The published constructor retains its parameter order and value types. */
    public constructor(
        rawMode: Int,
        settings: Map<SettingKey, SettingValue>,
        recording: Boolean? = false,
        batteryPercent: Int? = null,
        freeBytes: Long? = null,
        timecode: CameraTimecode? = null,
        audioLevels: AudioLevels? = null,
    ) : this(rawMode, settings, recording, batteryPercent, freeBytes, timecode, audioLevels, timecode?.let { CameraTimecodeReading(it) })

    /** Copy the published fields without losing an unchanged precision-rich reading. */
    public fun copy(
        rawMode: Int = this.rawMode,
        settings: Map<SettingKey, SettingValue> = this.settings,
        recording: Boolean? = this.recording,
        batteryPercent: Int? = this.batteryPercent,
        freeBytes: Long? = this.freeBytes,
        timecode: CameraTimecode? = this.timecode,
        audioLevels: AudioLevels? = this.audioLevels,
    ): FakeDevice = FakeDevice(rawMode, settings, recording, batteryPercent, freeBytes, timecode, audioLevels,
        if (timecode == this.timecode) timecodeReading else timecode?.let { CameraTimecodeReading(it) })

    /** Replace the precise value, projecting the legacy field only when representable. */
    public fun withTimecodeReading(value: CameraTimecodeReading?): FakeDevice =
        FakeDevice(rawMode, settings, recording, batteryPercent, freeBytes, value?.frameTimecode, audioLevels, value)

    public constructor(
        rawMode: Int, settings: Map<SettingKey, SettingValue>, recording: Boolean? = false,
        batteryPercent: Int? = null, freeBytes: Long? = null, timecodeReading: CameraTimecodeReading?,
        audioLevels: AudioLevels? = null,
    ) : this(rawMode, settings, recording, batteryPercent, freeBytes, timecodeReading?.frameTimecode, audioLevels, timecodeReading)
}

/**
 * A deterministic [CameraSession] on a manual clock. Nothing happens between calls: tests move
 * time with [advance] and drive the camera side with the `camera...` and link methods.
 *
 * A connected session (epoch 1) that has not heard from the camera yet: everything unknown.
 */
// ponytail: confined to one thread (runBlocking or runTest), no lock; add a Mutex if a test drives one fake from several threads.
public class FakeCameraSession(
    public val behavior: FakeCameraBehavior,
    device: FakeDevice,
    authority: ControlAuthority = ControlAuthority.Owner,
) : CameraSession {
    override val id: CameraSessionID = CameraSessionID()

    public var device: FakeDevice = device
        private set
    public var now: MonotonicInstant = MonotonicInstant.ZERO
        private set
    public var current: CameraSnapshot = CameraSnapshot(
        session = id,
        epoch = ControlEpoch(1),
        device = CameraDeviceID.provisional(behavior.integration),
        connection = ConnectionState.Ready,
        authority = authority,
    )
        private set
    public var liveViewReady: Boolean = false
        private set

    private val state = MutableStateFlow(current)
    override val snapshots: StateFlow<CameraSnapshot> = state.asStateFlow()

    private val sent = mutableListOf<String>()

    /** Every command that reached the camera, in order. */
    public val wire: List<String> get() = sent.toList()

    private class Write(val intent: CameraCommandIntent, val dropped: Boolean)
    private class Scheduled(val at: MonotonicInstant, val order: Int, val operation: OperationID, val timeout: Boolean)

    private var attempt = ConnectionAttemptID()
    private val receipts = mutableMapOf<OperationID, CommandReceipt>()
    private val history = mutableMapOf<OperationID, MutableList<CommandStage>>()
    private val writes = mutableMapOf<OperationID, Write>()
    private val queue = mutableListOf<Scheduled>()
    private var order = 0
    private val waiters = mutableMapOf<OperationID, CompletableDeferred<CommandReceipt>>()
    private var refuseNext = false
    private var dropNext = false
    private var reportsSilenced = false

    public val subscriberCount: Int get() = state.subscriptionCount.value

    public fun stages(operation: OperationID): List<CommandStage> = history[operation].orEmpty().toList()

    // Camera side

    /** The camera pushes a full status report. A report from a superseded attempt is ignored. */
    public fun cameraReportsStatus(from: ConnectionAttemptID? = null) {
        if (from != null && from != attempt) return
        if (current.connection != ConnectionState.Ready || reportsSilenced) return
        report()
    }

    /** The camera's counter advances (a live-view header, a status push): only the timecode changes. */
    public fun cameraReportsTimecode(timecode: CameraTimecode?) {
        device = device.withTimecodeReading(timecode?.let { CameraTimecodeReading(it) })
        cameraReportsStatus()
    }

    public fun cameraReportsTimecodeReading(timecode: CameraTimecodeReading?) {
        device = device.withTimecodeReading(timecode)
        cameraReportsStatus()
    }

    /** The camera reports a setting changed on its own side (a body dial, a format readback). Swift twin. */
    public fun cameraReportsSetting(value: SettingValue) {
        device = device.copy(settings = device.settings + (value.key to value))
        cameraReportsStatus()
    }

    /** A camera-body recording report, independent of any app command. */
    public fun cameraReportsRecording(recording: Boolean?) {
        device = device.copy(recording = recording)
        if (recording == null) current = current.copy(recording = ObservedValue.unknown)
        cameraReportsStatus()
    }

    /** The operator turns the mode dial. Values the new mode cannot hold move to its first choice. */
    public fun cameraSwitchesMode(raw: Int) {
        var settings = device.settings
        for (descriptor in behavior.modes[raw]?.descriptors.orEmpty()) {
            val domain = descriptor.domain ?: continue
            val value = settings[descriptor.key] ?: continue
            val first = domain.choices.firstOrNull() ?: continue
            if (value !in domain) settings = settings + (descriptor.key to first)
        }
        device = device.copy(rawMode = raw, settings = settings)
        cameraReportsStatus()
    }

    public fun setLiveViewReady(ready: Boolean) {
        liveViewReady = ready
        if (!current.mode.isKnown) return
        refreshCapabilities()
        publish()
    }

    public fun setAuthority(authority: ControlAuthority) {
        current = current.copy(authority = authority)
        publish()
    }

    /** The camera NACKs the next command that reaches it. */
    public fun refuseNextCommand() {
        refuseNext = true
    }

    /** The camera acknowledges the next write but does not store it. */
    public fun dropNextWrite() {
        dropNext = true
    }

    /** The camera stops (or resumes) sending status reports. */
    public fun silenceReports(silenced: Boolean) {
        reportsSilenced = silenced
    }

    // Link

    /**
     * The link drops. Sent operations become OutcomeUnknown (the camera may still act);
     * recovery starts with a new attempt. Reported values stay as last reported.
     */
    public fun loseLink(): ConnectionAttemptID {
        for (operation in receipts.filterValues { !it.isFinished }.keys) {
            transition(operation, CommandStage.OutcomeUnknown)
        }
        return beginAttempt()
    }

    /** A new recovery attempt supersedes the current one. */
    public fun beginAttempt(): ConnectionAttemptID {
        attempt = ConnectionAttemptID()
        current = current.copy(connection = ConnectionState.Recovering(attempt))
        publish()
        return attempt
    }

    /**
     * A link-up callback. Ignored unless it belongs to the current attempt. The replacement
     * link advances the control epoch.
     */
    public fun completeAttempt(completed: ConnectionAttemptID) {
        if (completed != attempt || current.connection !is ConnectionState.Recovering) return
        current = current.copy(connection = ConnectionState.Ready, epoch = current.epoch.next())
        publish()
    }

    /** Moves the manual clock, delivering due camera reports and timeouts in time order. */
    public fun advance(by: Duration) {
        val end = now + by
        while (true) {
            val next = queue.minWithOrNull(compareBy<Scheduled> { it.at }.thenBy { it.order }) ?: break
            if (next.at > end) break
            queue.remove(next)
            now = next.at
            if (!next.timeout) {
                apply(next.operation)
            } else if (receipts[next.operation]?.stage == CommandStage.AwaitingObservation) {
                transition(next.operation, CommandStage.TimedOut)
            }
        }
        now = end
    }

    // CameraSession

    override suspend fun submit(command: CameraCommand): CommandReceipt {
        val operation = command.operation
        receipts[operation]?.let { return it }
        receipts[operation] = CommandReceipt(
            operation, id, command.intent,
            confirmation = current.capabilities[command.intent.key]?.semantics?.confirmation
                ?: SettingSemantics.Confirmation.READBACK,
        )
        history[operation] = mutableListOf(CommandStage.Created)

        val rejection = current.rejection(command, now) ?: integrationRejection(command.intent)
        if (rejection != null) return transition(operation, CommandStage.Rejected(rejection))
        transition(operation, CommandStage.Admitted)
        supersedeEarlierWrites(command.intent, operation)
        if (alreadyReported(command.intent)) return transition(operation, CommandStage.Confirmed)

        sent += wireCommand(command.intent)
        transition(operation, CommandStage.Sent)
        if (refuseNext) {
            refuseNext = false
            return transition(operation, CommandStage.Rejected(CommandRejection.CameraRefused))
        }
        val accepted = transition(operation, CommandStage.Accepted)
        if (accepted.isFinished) return accepted

        writes[operation] = Write(command.intent, dropNext)
        dropNext = false
        schedule(operation, now + behavior.reportDelay, timeout = false)
        var timeout = now + behavior.observationTimeout
        command.preconditions.deadline?.let { if (it < timeout) timeout = it }
        schedule(operation, timeout, timeout = true)
        return transition(operation, CommandStage.AwaitingObservation)
    }

    override suspend fun outcome(operation: OperationID): CommandReceipt? {
        val receipt = receipts[operation] ?: return null
        if (receipt.isFinished) return receipt
        return waiters.getOrPut(operation) { CompletableDeferred() }.await()
    }

    override fun receipt(operation: OperationID): CommandReceipt? = receipts[operation]

    override suspend fun close(reason: SessionCloseReason): Unit = closeNow(reason)

    /** Closing does not suspend here, so the non-suspending form closes at once. */
    override fun closeNow(reason: SessionCloseReason) {
        if (current.connection is ConnectionState.Disconnected) return
        for ((operation, receipt) in receipts.filterValues { !it.isFinished }) {
            val stage = when (receipt.stage) {
                CommandStage.Created, CommandStage.Admitted -> CommandStage.Failed(CommandFailure.NOT_SENT)
                else -> CommandStage.OutcomeUnknown
            }
            transition(operation, stage)
        }
        writes.clear()
        queue.clear()
        current = current.copy(
            connection = ConnectionState.Disconnected(reason),
            authority = ControlAuthority.Unavailable(UnavailableReason.Link),
        )
        publish()
    }

    // Internals

    private fun integrationRejection(intent: CameraCommandIntent): CommandRejection? {
        if (behavior.recordWire != FakeCameraBehavior.RecordWire.TOGGLE) return null
        return when (intent) {
            CameraCommandIntent.StartRecording, CameraCommandIntent.StopRecording ->
                when (current.recording.value) {
                    RecordingState.IDLE, RecordingState.RECORDING -> null
                    else -> CommandRejection.RecordingStateUnknown
                }
            is CameraCommandIntent.Set, is CameraCommandIntent.FocusPoint -> null
        }
    }

    /**
     * Coalescing policy: an admitted write retires every unfinished write to the same setting.
     * The camera still acts on what it already received; only the newest receipt can confirm.
     */
    private fun supersedeEarlierWrites(intent: CameraCommandIntent, newer: OperationID) {
        if (intent !is CameraCommandIntent.Set) return
        val earlier = receipts.filter { (operation, receipt) ->
            operation != newer && !receipt.isFinished && receipt.intent is CameraCommandIntent.Set &&
                receipt.intent.key == intent.key
        }
        for (operation in earlier.keys) transition(operation, CommandStage.Failed(CommandFailure.SUPERSEDED))
    }

    /**
     * Idempotency policy: a start while the camera reports recording (or a stop while idle) is
     * confirmed without touching the wire, so a retry can never undo the first success.
     */
    private fun alreadyReported(intent: CameraCommandIntent): Boolean = when (intent) {
        CameraCommandIntent.StartRecording -> current.recording.value == RecordingState.RECORDING
        CameraCommandIntent.StopRecording -> current.recording.value == RecordingState.IDLE
        is CameraCommandIntent.Set, is CameraCommandIntent.FocusPoint -> false
    }

    private fun wireCommand(intent: CameraCommandIntent): String {
        val toggle = behavior.recordWire == FakeCameraBehavior.RecordWire.TOGGLE
        return when (intent) {
            is CameraCommandIntent.Set -> "set ${intent.value}"
            CameraCommandIntent.StartRecording -> if (toggle) "record-toggle" else "record-start"
            CameraCommandIntent.StopRecording -> if (toggle) "record-toggle" else "record-stop"
            is CameraCommandIntent.FocusPoint -> "focus-point"
        }
    }

    private fun schedule(operation: OperationID, at: MonotonicInstant, timeout: Boolean) {
        order += 1
        queue += Scheduled(at, order, operation, timeout)
    }

    /** The camera acts on a write, then (link and reports permitting) reports back. */
    private fun apply(operation: OperationID) {
        val write = writes.remove(operation) ?: return
        if (!write.dropped) {
            val toggle = behavior.recordWire == FakeCameraBehavior.RecordWire.TOGGLE
            device = when (val intent = write.intent) {
                is CameraCommandIntent.Set -> device.copy(settings = device.settings + (intent.value.key to intent.value))
                CameraCommandIntent.StartRecording -> device.copy(recording = if (toggle) device.recording != true else true)
                CameraCommandIntent.StopRecording -> device.copy(recording = if (toggle) device.recording != true else false)
                is CameraCommandIntent.FocusPoint -> device
            }
        }
        if (current.connection != ConnectionState.Ready || reportsSilenced) return
        report()
        if (receipts[operation]?.stage != CommandStage.AwaitingObservation) return
        transition(
            operation,
            if (reportShows(write.intent)) CommandStage.Confirmed else CommandStage.Failed(CommandFailure.NOT_APPLIED),
        )
    }

    private fun reportShows(intent: CameraCommandIntent): Boolean = when (intent) {
        is CameraCommandIntent.Set -> current.value(intent.value.key).value == intent.value
        CameraCommandIntent.StartRecording -> current.recording.value == RecordingState.RECORDING
        CameraCommandIntent.StopRecording -> current.recording.value == RecordingState.IDLE
        is CameraCommandIntent.FocusPoint -> true
    }

    private fun report() {
        val raw = device.rawMode
        val mode = behavior.modes[raw]?.mode
            ?: CaptureMode(CaptureMode.Role.OTHER, "${behavior.integration.rawValue}.raw.$raw", "Mode $raw")
        current = current.copy(mode = ObservedValue(mode, CAMERA_REPORTED, now))
        refreshCapabilities()
        var snapshot = current.copy(
            settings = device.settings
                .filterKeys { current.capabilities[it] != null }
                .mapValues { ObservedValue(it.value, CAMERA_REPORTED, now) },
        )
        device.recording?.let {
            val reported = if (it) RecordingState.RECORDING else RecordingState.IDLE
            snapshot = snapshot.copy(recording = ObservedValue(reported, CAMERA_REPORTED, now))
        }
        device.batteryPercent?.let {
            val battery = ObservedValue(it / 100.0, CAMERA_REPORTED, now, precision = ObservationPrecision.Quantized(0.01))
            snapshot = snapshot.copy(power = snapshot.power.copy(battery = battery))
        }
        device.freeBytes?.let {
            val volume = StorageVolume(
                "card",
                media = ObservedValue(MediaState.READY, CAMERA_REPORTED, now),
                freeBytes = ObservedValue(it, CAMERA_REPORTED, now),
            )
            snapshot = snapshot.copy(storage = ObservedValue(listOf(volume), CAMERA_REPORTED, now))
        }
        val capabilities = snapshot.capabilities
        snapshot = snapshot.withTimecodeReading(
            device.timecodeReading?.takeIf { capabilities.timecode == SupportStatus.SUPPORTED }
                ?.let { ObservedValue(it, behavior.timecodeOrigin, now) } ?: ObservedValue.unknown,
        ).copy(
            audioLevels = device.audioLevels?.takeIf { capabilities.audioLevels == SupportStatus.SUPPORTED }
                ?.let { ObservedValue(it, CAMERA_REPORTED, now) } ?: ObservedValue.unknown,
        )
        current = snapshot
        publish()
    }

    private fun refreshCapabilities() {
        val fakeMode = behavior.modes[device.rawMode]
        var descriptors = fakeMode?.descriptors.orEmpty()
        val unsupported = fakeMode?.unsupported.orEmpty()
        if (behavior.recordNeedsLiveView && !liveViewReady) {
            descriptors = descriptors.map {
                if (it.key == SettingKey.RECORDING && it.availability == Availability.Available) {
                    it.copy(availability = Availability.Unavailable(UnavailableReason.NotReady))
                } else {
                    it
                }
            }
        }
        val revision = current.capabilities.revision
        val timecode = fakeMode?.timecodeCapability ?: TimecodeCapability.unknown
        val audioLevels = fakeMode?.audioLevels ?: SupportStatus.UNKNOWN
        val next = CapabilitySnapshot(timecodeCapability = timecode, revision = revision, descriptors = descriptors, unsupported = unsupported, audioLevels = audioLevels)
        if (next == current.capabilities) return
        current = current.copy(capabilities = next.copy(revision = revision.next()))
    }

    private fun publish() {
        current = current.copy(revision = current.revision.next())
        state.value = current
    }

    private fun transition(operation: OperationID, stage: CommandStage): CommandReceipt {
        val receipt = receipts.getValue(operation).copy(stage = stage)
        receipts[operation] = receipt
        history.getOrPut(operation) { mutableListOf() } += stage
        if (receipt.isFinished) waiters.remove(operation)?.complete(receipt)
        return receipt
    }

    public companion object
}
