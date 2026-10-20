package com.opencapture.opencine.appkit

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CameraTimecode
import com.opencapture.opencine.core.CameraTimecodeReading
import com.opencapture.opencine.core.CaptureMode
import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandDispatchAdmission
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.CommandReceipt
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.ObservedValue
import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.ObservationOrigin
import com.opencapture.opencine.core.ObservationPrecision
import com.opencapture.opencine.core.ObservationValidity
import com.opencapture.opencine.core.OperationID
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.UnavailableReason
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.transformWhile
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive

/**
 * The common controls of the monitor's camera (Swift `MonitorControlModel`, SHELL-03): one
 * snapshot collector, the operator's pending edits, explicit record start and stop, and open
 * editors. Confine it to the main thread; [scope] runs the collector and the operations.
 *
 * - Reported values come only from the session's snapshots. A pending edit is presentation
 *   state: [shown] puts it over the report while its operation is unfinished; it is never written
 *   into the snapshot.
 * - Edits coalesce per setting (latest wins) for [coalescingMs], then go out as one
 *   [CameraCommand] against the snapshot of that moment.
 * - Record resolves an explicit start or stop against the current snapshot; an unknown recording
 *   state sends nothing.
 * - An [Editor] remembers the session, control epoch, authority and domain it was opened under;
 *   once any of them changes, the editor is obsolete and its commit is refused.
 * - [unbind] retires everything: a receipt, snapshot or record outcome from a retired binding is
 *   dropped, so a late answer from an old camera never reaches the next one. It never closes the
 *   session (the shell decides that).
 */
public class MonitorControlModel(
    private val scope: CoroutineScope,
    private val coalescingMs: Long = 120,
    delay: suspend (Long) -> Unit = { kotlinx.coroutines.delay(it) },
) {
    /** One open editor (a drum, a picker) and the assumptions it was opened under. */
    public data class Editor internal constructor(
        public val key: SettingKey,
        internal val binding: Int,
        internal val session: CameraSessionID,
        internal val epoch: ControlEpoch,
        internal val authority: ControlAuthority,
        internal val domain: SettingDomain?,
        internal val localRevision: Long = 0,
    )

    /**
     * A captured target under binding, mode, epoch, authority and domain assumptions. A recording report
     * that changes the captured Start or Stop retires it: approval never inverts.
     */
    public data class RecordEditor internal constructor(
        public val recording: Boolean,
        internal val editor: Editor,
        internal val mode: CaptureMode,
    )

    public data class State(
        /** The session the controls drive; `null` when nothing is bound. */
        public val session: CameraSession? = null,
        /**
         * The latest snapshot of [session]. A report that changes only the timecode is not
         * re-emitted, so its timecode and revision may lag: read [MonitorControlModel.timecode].
         */
        public val snapshot: CameraSnapshot? = null,
        /** Operator targets whose operations are unfinished. */
        public val pending: Map<SettingKey, SettingValue> = emptyMap(),
        /** A record start or stop is in flight. */
        public val recordPending: Boolean = false,
    )

    private val sleep = delay
    private val mutable = MutableStateFlow(State())
    public val state: StateFlow<State> = mutable.asStateFlow()

    /**
     * The latest reported timecode, observed on its own (Compose state): a per-frame counter
     * re-renders the clock that reads it, not every collector of [state].
     */
    public val timecode: ObservedValue<CameraTimecode>
        get() = timecodeReading.compactMap { it.frameTimecode }

    public var timecodeReading: ObservedValue<CameraTimecodeReading> by mutableStateOf(ObservedValue.unknown)
        private set

    /** Operator copy for an outcome that is not a confirmation (and for refusing to send). */
    public var onNote: (String) -> Unit = {}

    /** The copy for a finished write or record ([note] by default); `null` stays silent. A host may keep its own. */
    public var noteFor: (CommandStage, String) -> String? = { stage, label -> note(stage, label) }

    /** A record operation finished (any stage), for the app's follow-up (refresh media). */
    public var onRecordFinished: (CommandReceipt) -> Unit = {}
    /**
     * Every setting write's outcome with its operator label, including one refused before it was
     * sent (out of domain, unavailable): for the app's diagnostic journal, never operator copy.
     */
    public var onWriteFinished: (String, CommandReceipt) -> Unit = { _, _ -> }

    /** The reported state or a pending target changed: for projections that still copy it. */
    public var onChange: () -> Unit = {}

    /** The bound session reported [ConnectionState.Disconnected]. Called once per binding. */
    internal var onEnded: () -> Unit = {}

    /**
     * Each field's drum, rebuilt only when its domain changes ([captureField]): a recomposition reads
     * it many times a second and a Kelvin domain spans up to a thousand detents (R-03).
     */
    internal val captureChoices = java.util.concurrent.ConcurrentHashMap<SettingKey, Pair<SettingDomain, List<MonitorCaptureChoice>>>()

    private var binding = 0
    private var feed: Job? = null
    private data class PendingEdit(
        val operation: OperationID, val label: String, val editor: Editor?,
        val admission: CommandDispatchAdmission?,
    )
    private val operations = HashMap<SettingKey, PendingEdit>()
    private val scheduled = HashSet<SettingKey>()
    private val editRevisions = HashMap<SettingKey, Long>()
    private var recordOperation: OperationID? = null


    /** Clock-derived counter from a fresh camera-confirmed start; an unknown start stays unknown. */
    public var recordingElapsed: ObservedValue<Int> by mutableStateOf(ObservedValue.unknown)
        private set
    private var recordingStartedAt: MonotonicInstant? = null
    private var recordingTicker: Job? = null
    private var recordingNow: () -> MonotonicInstant = { MonotonicInstant.now() }
    private var recordingDelay: suspend (Long) -> Unit = { kotlinx.coroutines.delay(it) }

    /** Additive deterministic timing overload; the existing positional/trailing-delay API is intact. */
    public constructor(scope: CoroutineScope, now: () -> MonotonicInstant,
        recordingDelay: suspend (Long) -> Unit = { kotlinx.coroutines.delay(it) },
        coalescingMs: Long = 120, delay: suspend (Long) -> Unit = { kotlinx.coroutines.delay(it) }) :
        this(scope, coalescingMs, delay) {
        recordingNow = now
        this.recordingDelay = recordingDelay
    }

    private fun retireRecordingElapsed() {
        recordingTicker?.cancel(); recordingTicker = null
        recordingStartedAt = null
        recordingElapsed = ObservedValue.unknown
    }

    private fun updateRecordingElapsed(at: MonotonicInstant) {
        val start = recordingStartedAt
        if (start == null || at < start) { retireRecordingElapsed(); return }
        val seconds = (at - start).inWholeSeconds
        if (seconds > Int.MAX_VALUE) { retireRecordingElapsed(); return }
        if (recordingElapsed.value != seconds.toInt()) {
            recordingElapsed = ObservedValue(seconds.toInt(), ObservationOrigin.CLOCK_DERIVED, at,
                precision = ObservationPrecision.Quantized(1.0))
        }
    }

    private fun observeRecordingElapsed(value: CameraSnapshot) {
        val previous = mutable.value.snapshot
        val sameOwner = previous?.session == value.session && previous.epoch == value.epoch
        if (!sameOwner) retireRecordingElapsed()
        if (value.connection != ConnectionState.Ready || value.recording.validity != ObservationValidity.Valid) {
            retireRecordingElapsed(); return
        }
        when (value.recording.value) {
            RecordingState.IDLE -> {
                recordingTicker?.cancel(); recordingTicker = null
                recordingStartedAt = null
                if (recordingElapsed.value != 0) {
                    recordingElapsed = ObservedValue(0, ObservationOrigin.CLOCK_DERIVED, recordingNow(),
                        precision = ObservationPrecision.Quantized(1.0))
                }
            }
            RecordingState.RECORDING -> {
                if (recordingStartedAt != null || !sameOwner || previous?.recording?.value != RecordingState.IDLE ||
                    previous.recording.validity != ObservationValidity.Valid) return
                recordingStartedAt = recordingNow()
                updateRecordingElapsed(recordingNow())
                val current = binding
                recordingTicker = scope.launch {
                    while (isActive && binding == current && recordingStartedAt != null) {
                        recordingDelay(1000)
                        if (!isActive || binding != current || recordingStartedAt == null) return@launch
                        updateRecordingElapsed(recordingNow())
                    }
                }
            }
            else -> retireRecordingElapsed()
        }
    }

    // Binding

    /**
     * Makes [session] the target of the controls and follows its snapshots (the only collector).
     * A previous binding is retired first.
     */
    public fun bind(session: CameraSession) {
        unbind()
        val current = binding
        mutable.update { it.copy(session = session) }
        feed = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            if (!isActive || binding != current) return@launch
            session.snapshots
                .transformWhile { emit(it); it.connection !is ConnectionState.Disconnected }
                .collect { if (binding == current) apply(it) }
            if (binding != current) return@launch
            feed = null
            retireRecordingElapsed()
            onEnded()
        }
    }

    /**
     * Retires the binding: stops following, drops pending edits and record state, obsoletes every
     * editor. Never closes the session and never sends a command.
     */
    public fun unbind() {
        retireRecordingElapsed()
        binding += 1
        feed?.cancel()
        feed = null
        val changed = mutable.value.snapshot != null || mutable.value.pending.isNotEmpty()
        operations.clear()
        scheduled.clear()
        editRevisions.clear()
        recordOperation = null
        rateChangeWake?.cancel()
        rateChangeWake = null
        frameRateSettling = false
        mutable.value = State()
        timecodeReading = ObservedValue.unknown
        if (changed) onChange()
    }

    /**
     * True for [RATE_CHANGE_HOLD] after the camera reports a new recording frame rate (one known
     * rate replaced by another). Speeds and rates arrive from two moments around a format change,
     * so readouts that pair them (an emulated shutter angle) hold the operator's value meanwhile.
     * Compose state: the end of the hold redraws without waiting for another snapshot. Swift twin.
     */
    public var frameRateSettling: Boolean by mutableStateOf(false)
        private set
    private var rateChangeWake: Job? = null

    private fun openRateChangeHold() {
        frameRateSettling = true
        rateChangeWake?.cancel()
        val current = binding
        rateChangeWake = scope.launch {
            recordingDelay(RATE_CHANGE_HOLD.inWholeMilliseconds)
            if (!isActive || binding != current) return@launch
            rateChangeWake = null
            frameRateSettling = false
            onChange()
        }
    }

    private fun apply(snapshot: CameraSnapshot) {
        val before = mutable.value.snapshot
        val nextRate = snapshot.value(SettingKey.FRAME_RATE).value
        val previousRate = before?.value(SettingKey.FRAME_RATE)?.value
        if (nextRate is com.opencapture.opencine.core.SettingValue.FrameRate &&
            previousRate is com.opencapture.opencine.core.SettingValue.FrameRate && previousRate != nextRate &&
            before.session == snapshot.session) openRateChangeHold()
        observeRecordingElapsed(snapshot)
        val previous = mutable.value.snapshot
        if (previous?.copy(revision = snapshot.revision)?.withTimecodeReading(snapshot.timecodeReading) != snapshot) {
            mutable.update { it.copy(snapshot = snapshot) }
        }
        timecodeReading = snapshot.timecodeReading
        onChange()
    }

    // Readouts

    /** The operator's pending target, else the reported value; `null` is unknown. */
    public fun shown(key: SettingKey): SettingValue? = state.value.let { it.pending[key] ?: it.snapshot?.value(key)?.value }

    /** Camera-reported recording; `null` while unknown (never idle). */
    public val recording: RecordingState? get() = state.value.snapshot?.recording?.value

    /** Recording as a yes or no only when the camera reports one of the two; otherwise `null`. */
    public val isRecording: Boolean?
        get() = when (recording) {
            RecordingState.RECORDING -> true
            RecordingState.IDLE -> false
            else -> null
        }

    // Editing

    /** Opens an editor for [key] under the current assumptions; `null` without a described setting. */
    public fun edit(key: SettingKey): Editor? {
        val snapshot = state.value.snapshot ?: return null
        val descriptor = snapshot.capabilities[key] ?: return null
        return Editor(key, binding, snapshot.session, snapshot.epoch, snapshot.authority, descriptor.domain,
            editRevisions[key] ?: 0)
    }

    /** Whether [editor] still describes this session, epoch, authority and domain. */
    public fun isCurrent(editor: Editor): Boolean {
        val snapshot = state.value.snapshot ?: return false
        return editor.binding == binding && editor.localRevision == (editRevisions[editor.key] ?: 0) &&
            editor.session == snapshot.session && editor.epoch == snapshot.epoch &&
            editor.authority == snapshot.authority && editor.domain == snapshot.capabilities[editor.key]?.domain
    }

    /** Sets [value] from an open editor. Refused (`false`, nothing sent) once the editor is obsolete. */
    public fun commit(value: SettingValue, editor: Editor, label: String): Boolean {
        if (!admits(value, editor)) return false
        set(value, label, editor, null)
        return true
    }

    public fun commit(
        value: SettingValue, editor: Editor, label: String, admission: CommandDispatchAdmission,
    ): Boolean {
        if (!admits(value, editor)) return false
        set(value, label, editor, admission)
        return true
    }

    /** Retires one local setting edit and its captured editors. Sent camera work continues;
     * its receipt cannot clear a successor. No command or owner epoch change. */
    public fun cancelEdit(key: SettingKey) {
        editRevisions[key] = (editRevisions[key] ?: 0) + 1
        operations.remove(key)
        scheduled.remove(key)
        mutable.update { it.copy(pending = it.pending - key) }
        onChange()
    }

    private fun admits(value: SettingValue, editor: Editor): Boolean {
        val snapshot = state.value.snapshot ?: return false
        val descriptor = snapshot.capabilities[editor.key] ?: return false
        return value.key == editor.key && isCurrent(editor) && snapshot.connection == ConnectionState.Ready &&
            descriptor.access == SettingAccess.READ_WRITE && descriptor.availability == Availability.Available &&
            descriptor.accepts(value) && (snapshot.authority == ControlAuthority.Owner || snapshot.authority is ControlAuthority.Lease)
    }

    /**
     * Shows [value] at once and sends it after the coalescing window; a newer value for the same
     * setting replaces it. [label] names it in operator notes ("ISO 800").
     */
    public fun set(value: SettingValue, label: String): Unit = set(value, label, null, null)

    public fun set(value: SettingValue, label: String, admission: CommandDispatchAdmission): Unit =
        set(value, label, null, admission)

    private fun set(
        value: SettingValue, label: String, editor: Editor?, admission: CommandDispatchAdmission?,
    ) {
        if (state.value.session == null) return onNote(CONNECT_FIRST)
        val key = value.key
        mutable.update { it.copy(pending = it.pending + (key to value)) }
        operations[key] = PendingEdit(OperationID(), label, editor, admission)
        onChange()
        if (!scheduled.add(key)) return
        val current = binding
        val revision = editRevisions[key] ?: 0
        scope.launch {
            sleep(coalescingMs)
            if (binding != current || (editRevisions[key] ?: 0) != revision) return@launch
            scheduled.remove(key)
            submit(key)
        }
    }

    private fun submit(key: SettingKey) {
        val (operation, label, editor, admission) = operations[key] ?: return
        val value = state.value.pending[key] ?: return
        if (editor != null && !admits(value, editor)) return finish(key, operation, binding, null)
        val session = state.value.session
        val snapshot = state.value.snapshot
        if (session == null || snapshot == null) return finish(key, operation, binding, CONNECT_FIRST)
        val command = CameraCommand(CameraCommandIntent.Set(value), CommandPreconditions(snapshot), operation)
        val current = binding
        scope.launch {
            val receipt = finished(session, command, admission)
            onWriteFinished(label, receipt)
            finish(key, operation, current, noteFor(receipt.stage, label))
        }
    }

    private fun finish(key: SettingKey, operation: OperationID, from: Int, note: String?) {
        // A retired binding, or a newer edit of the same setting, owns the control now.
        if (from != binding || operations[key]?.operation != operation) return
        operations.remove(key)
        mutable.update { it.copy(pending = it.pending - key) }
        onChange()
        note?.let(onNote)
    }

    // Record

    /**
     * Starts (`true`) or stops (`false`) recording; `null` resolves from the current report (stop
     * while recording, start while idle). Unknown sends nothing. One record operation at a time.
     */
    /** Unknown recording, mode, access or control readiness cannot be confirmed. */
    public fun recordEditor(): RecordEditor? = if (state.value.recordPending) null
        else state.value.snapshot?.let { recordEditor(it) }

    private fun recordEditor(snapshot: CameraSnapshot): RecordEditor? {
        val mode = snapshot.mode.value ?: return null
        val descriptor = snapshot.capabilities[SettingKey.RECORDING] ?: return null
        if (snapshot.connection != ConnectionState.Ready || mode.role != CaptureMode.Role.VIDEO ||
            descriptor.access != SettingAccess.READ_WRITE || descriptor.availability != Availability.Available ||
            (snapshot.authority != ControlAuthority.Owner && snapshot.authority !is ControlAuthority.Lease)) return null
        val recording = when (snapshot.recording.value) {
            RecordingState.IDLE -> false
            RecordingState.RECORDING -> true
            else -> return null
        }
        return RecordEditor(recording, Editor(SettingKey.RECORDING, binding, snapshot.session,
            snapshot.epoch, snapshot.authority, descriptor.domain, editRevisions[SettingKey.RECORDING] ?: 0), mode)
    }

    /** Checks the captured assumptions; unknown observation always retires approval. */
    public fun canCommitRecord(editor: RecordEditor): Boolean = !state.value.recordPending &&
        state.value.snapshot?.let { recordApprovalMatches(editor, it) } == true

    private fun recordApprovalMatches(editor: RecordEditor, snapshot: CameraSnapshot): Boolean {
        val current = recordEditor(snapshot) ?: return false
        return current.editor == editor.editor && current.mode == editor.mode && current.recording == editor.recording
    }

    /** Sends the captured target, rechecked against the fresh snapshot before dispatch. */
    public fun commitRecord(editor: RecordEditor): Boolean {
        if (!canCommitRecord(editor)) return false
        record(!editor.recording, editor)
        return true
    }

    public fun commitRecord(editor: RecordEditor, admission: CommandDispatchAdmission): Boolean {
        if (!canCommitRecord(editor)) return false
        beginRecord(!editor.recording, editor, admission)
        return true
    }

    public fun record(start: Boolean?) { beginRecord(start, null) }

    public fun record(start: Boolean?, admission: CommandDispatchAdmission) { beginRecord(start, null, admission) }

    /** Waits for the same terminal receipt as [record]; null means no operation or a retired binding. */
    public suspend fun recordAndWait(start: Boolean?): CommandReceipt? = beginRecord(start, null)?.await()

    public suspend fun recordAndWait(start: Boolean?, admission: CommandDispatchAdmission): CommandReceipt? =
        beginRecord(start, null, admission)?.await()

    private fun record(start: Boolean?, approved: RecordEditor?) { beginRecord(start, approved) }

    private fun beginRecord(
        start: Boolean?, approved: RecordEditor?, admission: CommandDispatchAdmission? = null,
    ): Deferred<CommandReceipt?>? {
        if (state.value.recordPending) return null
        val session = state.value.session ?: run { onNote(CONNECT_FIRST); return null }
        val operation = OperationID()
        val current = binding
        recordOperation = operation
        mutable.update { it.copy(recordPending = true) }
        return scope.async {
            val fresh = session.snapshots.value
            if (binding != current || (approved != null && !recordApprovalMatches(approved, fresh))) {
                finishRecord(operation, current, null, null)
                return@async null
            }
            val intent = when {
                start == true -> CameraCommandIntent.StartRecording
                start == false -> CameraCommandIntent.StopRecording
                fresh.recording.value == RecordingState.RECORDING -> CameraCommandIntent.StopRecording
                fresh.recording.value == RecordingState.IDLE -> CameraCommandIntent.StartRecording
                else -> null
            }
            if (intent == null) {
                finishRecord(operation, current, RECORDING_UNKNOWN, null)
                return@async null
            }
            val receipt = finished(session, CameraCommand(intent, CommandPreconditions(fresh), operation), admission)
            val label = if (intent == CameraCommandIntent.StartRecording) "Record" else "Stop"
            if (binding != current || recordOperation != operation) return@async null
            finishRecord(operation, current, noteFor(receipt.stage, label), receipt)
            receipt
        }
    }

    private fun finishRecord(operation: OperationID, from: Int, note: String?, receipt: CommandReceipt?) {
        if (from != binding || recordOperation != operation) return
        recordOperation = null
        mutable.update { it.copy(recordPending = false) }
        note?.let(onNote)
        receipt?.let(onRecordFinished)
    }

    public companion object {
        public const val CONNECT_FIRST: String = "Connect the camera to use its controls."
        public const val RECORDING_UNKNOWN: String = "Recording state is not known yet. Try again in a moment."

        /** How long [frameRateSettling] holds after a reported frame-rate change (Swift `rateChangeHold`). */
        public val RATE_CHANGE_HOLD: kotlin.time.Duration = 3.seconds

        private suspend fun finished(
            session: CameraSession, command: CameraCommand, admission: CommandDispatchAdmission? = null,
        ): CommandReceipt {
            val receipt = admission?.dispatch(command, session.id) ?: session.submit(command)
            if (receipt.isFinished) return receipt
            return session.outcome(command.operation) ?: receipt
        }

        /**
         * Operator copy for an outcome that is not a confirmation; `null` for a confirmation or a
         * superseded write (the newer receipt carries the outcome).
         */
        public fun note(stage: CommandStage, label: String): String? = when (stage) {
            CommandStage.Confirmed -> null
            is CommandStage.Rejected -> when (val rejection = stage.rejection) {
                CommandRejection.CameraRefused -> "$label: the camera refused it."
                CommandRejection.OutOfDomain, CommandRejection.Unsupported, CommandRejection.SupportUnknown ->
                    "$label is not offered by this camera."
                CommandRejection.StaleCapabilities, CommandRejection.StaleEpoch ->
                    "$label was not sent: the camera state changed. Try again."
                is CommandRejection.Unavailable ->
                    if (rejection.reason == UnavailableReason.Mode) "$label is not available in this mode." else "$label is not available right now."
                else -> CONNECT_FIRST
            }
            is CommandStage.Failed -> when (stage.failure) {
                CommandFailure.NOT_APPLIED -> "$label was not applied by the camera."
                CommandFailure.NOT_SENT -> "$label was not sent."
                CommandFailure.SUPERSEDED -> null
            }
            CommandStage.OutcomeUnknown -> "$label: the camera link dropped before it confirmed."
            else -> "The camera did not confirm $label."
        }
    }
}
