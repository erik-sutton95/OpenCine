package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CameraSnapshot
import com.opencapture.opencine.core.CaptureMode
import com.opencapture.opencine.core.Availability
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.CommandReceipt
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.OperationID
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.UnavailableReason
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
    )

    /** An explicit record confirmation authorizes exactly this camera state. */
    public data class RecordEditor internal constructor(
        public val recording: Boolean,
        internal val editor: Editor,
        internal val mode: CaptureMode,
    )

    public data class State(
        /** The session the controls drive; `null` when nothing is bound. */
        public val session: CameraSession? = null,
        /** The latest snapshot of [session]. */
        public val snapshot: CameraSnapshot? = null,
        /** Operator targets whose operations are unfinished. */
        public val pending: Map<SettingKey, SettingValue> = emptyMap(),
        /** A record start or stop is in flight. */
        public val recordPending: Boolean = false,
    )

    private val sleep = delay
    private val mutable = MutableStateFlow(State())
    public val state: StateFlow<State> = mutable.asStateFlow()

    /** Operator copy for an outcome that is not a confirmation (and for refusing to send). */
    public var onNote: (String) -> Unit = {}

    /** A record operation finished (any stage), for the app's follow-up (refresh media). */
    public var onRecordFinished: (CommandReceipt) -> Unit = {}

    /** The reported state or a pending target changed: for projections that still copy it. */
    public var onChange: () -> Unit = {}

    /** The bound session reported [ConnectionState.Disconnected]. Called once per binding. */
    internal var onEnded: () -> Unit = {}

    private var binding = 0
    private var feed: Job? = null
    private data class PendingEdit(val operation: OperationID, val label: String, val editor: Editor?)
    private val operations = HashMap<SettingKey, PendingEdit>()
    private val scheduled = HashSet<SettingKey>()
    private var recordOperation: OperationID? = null

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
            session.snapshots
                .transformWhile { emit(it); it.connection !is ConnectionState.Disconnected }
                .collect { if (binding == current) apply(it) }
            if (binding != current) return@launch
            feed = null
            onEnded()
        }
    }

    /**
     * Retires the binding: stops following, drops pending edits and record state, obsoletes every
     * editor. Never closes the session and never sends a command.
     */
    public fun unbind() {
        binding += 1
        feed?.cancel()
        feed = null
        val changed = mutable.value.snapshot != null || mutable.value.pending.isNotEmpty()
        operations.clear()
        scheduled.clear()
        recordOperation = null
        mutable.value = State()
        if (changed) onChange()
    }

    private fun apply(snapshot: CameraSnapshot) {
        mutable.update { it.copy(snapshot = snapshot) }
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
        return Editor(key, binding, snapshot.session, snapshot.epoch, snapshot.authority, descriptor.domain)
    }

    /** Whether [editor] still describes this session, epoch, authority and domain. */
    public fun isCurrent(editor: Editor): Boolean {
        val snapshot = state.value.snapshot ?: return false
        return editor.binding == binding && editor.session == snapshot.session && editor.epoch == snapshot.epoch &&
            editor.authority == snapshot.authority && editor.domain == snapshot.capabilities[editor.key]?.domain
    }

    /** Sets [value] from an open editor. Refused (`false`, nothing sent) once the editor is obsolete. */
    public fun commit(value: SettingValue, editor: Editor, label: String): Boolean {
        if (!admits(value, editor)) return false
        set(value, label, editor)
        return true
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
    public fun set(value: SettingValue, label: String): Unit = set(value, label, null)

    private fun set(value: SettingValue, label: String, editor: Editor?) {
        if (state.value.session == null) return onNote(CONNECT_FIRST)
        val key = value.key
        mutable.update { it.copy(pending = it.pending + (key to value)) }
        operations[key] = PendingEdit(OperationID(), label, editor)
        onChange()
        if (!scheduled.add(key)) return
        val current = binding
        scope.launch {
            sleep(coalescingMs)
            if (binding != current) return@launch
            scheduled.remove(key)
            submit(key)
        }
    }

    private fun submit(key: SettingKey) {
        val (operation, label, editor) = operations[key] ?: return
        val value = state.value.pending[key] ?: return
        if (editor != null && !admits(value, editor)) return finish(key, operation, binding, null)
        val session = state.value.session
        val snapshot = state.value.snapshot
        if (session == null || snapshot == null) return finish(key, operation, binding, CONNECT_FIRST)
        val command = CameraCommand(CameraCommandIntent.Set(value), CommandPreconditions(snapshot), operation)
        val current = binding
        scope.launch { finish(key, operation, current, note(finished(session, command).stage, label)) }
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
        else state.value.snapshot?.let(::recordEditor)

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
            snapshot.epoch, snapshot.authority, descriptor.domain), mode)
    }

    /** Approval is retired on mode, epoch, authority, binding or recording changes. */
    public fun commitRecord(editor: RecordEditor): Boolean {
        if (recordEditor() != editor) return false
        record(!editor.recording, editor)
        return true
    }

    public fun record(start: Boolean?) { beginRecord(start, null) }

    /** Waits for the same terminal receipt as [record]; null means no operation or a retired binding. */
    public suspend fun recordAndWait(start: Boolean?): CommandReceipt? = beginRecord(start, null)?.await()

    private fun record(start: Boolean?, approved: RecordEditor?) { beginRecord(start, approved) }

    private fun beginRecord(start: Boolean?, approved: RecordEditor?): Deferred<CommandReceipt?>? {
        if (state.value.recordPending) return null
        val session = state.value.session ?: run { onNote(CONNECT_FIRST); return null }
        val operation = OperationID()
        val current = binding
        recordOperation = operation
        mutable.update { it.copy(recordPending = true) }
        return scope.async {
            val fresh = session.snapshots.value
            if (binding != current || (approved != null && recordEditor(fresh) != approved)) {
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
            val receipt = finished(session, CameraCommand(intent, CommandPreconditions(fresh), operation))
            val label = if (intent == CameraCommandIntent.StartRecording) "Record" else "Stop"
            if (binding != current || recordOperation != operation) return@async null
            finishRecord(operation, current, note(receipt.stage, label), receipt)
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

        private suspend fun finished(session: CameraSession, command: CameraCommand): CommandReceipt {
            val receipt = session.submit(command)
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
