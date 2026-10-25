import Foundation
import MonitorPresentation
import Observation
import OpenCineCore

/// The common controls of the monitor's camera (SHELL-03): one snapshot subscription, the
/// operator's pending edits, explicit record start and stop, and open editors.
///
/// - Reported values come only from the session's snapshots. A pending edit is presentation
///   state: `shown(_:)` puts it over the report while its operation is unfinished; it is never
///   written into `snapshot`.
/// - Edits coalesce per setting (latest wins) for `coalescing`, then go out as one
///   `CameraCommand` against the snapshot of that moment.
/// - Record resolves an explicit start or stop against a fresh snapshot; an unknown recording
///   state sends nothing.
/// - An `Editor` remembers the session, control epoch, authority and domain it was opened under;
///   once any of them changes, the editor is obsolete and its commit is refused.
/// - `unbind()` retires everything: a receipt, snapshot or record outcome from a retired binding
///   is dropped, so a late answer from an old camera never reaches the next one. It never
///   closes the session (the shell decides that).
///
/// Kotlin mirror: `MonitorControlModel` in `:appkit`, same names.
@available(macOS 14, *)
@MainActor
@Observable
public final class MonitorControlModel {
    /// One open editor (a drum, a picker) and the assumptions it was opened under.
    public struct Editor: Hashable, Sendable {
        public let key: SettingKey
        let binding: Int
        let session: CameraSessionID
        let epoch: ControlEpoch
        let authority: ControlAuthority
        let domain: SettingDomain?
        let localRevision: Int
    }

    /// An explicit record confirmation authorizes one target under captured control assumptions.
    /// A recording report that changes the captured Start or Stop retires it: approval never inverts.
    public struct RecordEditor: Hashable, Sendable {
        public let recording: Bool
        let editor: Editor
        let mode: CaptureMode
    }

    /// The session the controls drive; `nil` when nothing is bound.
    public private(set) var session: (any CameraSession)?
    /// The latest snapshot of `session`. A report that changes only the timecode updates it
    /// without notifying observers of `snapshot`; read `timecode` to follow the counter.
    public var snapshot: CameraSnapshot? {
        access(keyPath: \.snapshot)
        return latest
    }
    /// The latest reported timecode, observed on its own: a per-frame counter re-renders the
    /// clock that shows it, not every view that reads the snapshot.
    public var timecode: ObservedValue<CameraTimecode> {
        timecodeReading.compactMap { $0.frameTimecode }
    }
    public private(set) var timecodeReading: ObservedValue<CameraTimecodeReading> = .unknown
    /// The reported clock with every digit as 0, `nil` while unknown. It changes only when the
    /// clock's shape does (known, precision, hour width), so a status row laid out from it is not
    /// re-evaluated per frame; the clock readout follows `timecodeReading` on its own.
    public private(set) var timecodeTemplate: String?
    @ObservationIgnored private var latest: CameraSnapshot?
    /// Operator targets whose operations are unfinished.
    public private(set) var pending: [SettingKey: SettingValue] = [:]
    /// A record start or stop is in flight.
    public private(set) var recordPending = false

    /// Operator copy for an outcome that is not a confirmation (and for refusing to send).
    @ObservationIgnored public var onNote: (String) -> Void = { _ in }
    /// The copy for a finished write or record (`note(for:_:)` by default); `nil` stays silent.
    /// A host may keep its own.
    @ObservationIgnored public var noteFor: (CommandStage, String) -> String? = {
        MonitorControlModel.note(for: $0, $1)
    }
    /// A record operation finished (any stage), for the app's follow-up (refresh media).
    @ObservationIgnored public var onRecordFinished: (CommandReceipt) -> Void = { _ in }
    /// Every setting write's outcome with its operator label, including one refused before it was
    /// sent (out of domain, unavailable): for the app's diagnostic journal, never operator copy.
    @ObservationIgnored public var onWriteFinished: (String, CommandReceipt) -> Void = { _, _ in }
    /// The reported state or a pending target changed: for projections that still copy it.
    @ObservationIgnored public var onChange: () -> Void = {}
    /// The bound session reported `.disconnected` or ended its snapshots. Called once per binding.
    @ObservationIgnored var onEnded: () -> Void = {}
    /// Each field's drum, rebuilt only when its domain changes (`captureField`): a body pass
    /// reads it many times a second and a Kelvin domain spans up to a thousand detents (R-03).
    @ObservationIgnored var captureChoices: [SettingKey: (domain: SettingDomain, choices: [MonitorCaptureChoice])] = [:]

    @ObservationIgnored private let coalescing: Duration
    @ObservationIgnored private let sleep: @MainActor (Duration) async throws -> Void
    @ObservationIgnored private var binding = 0
    @ObservationIgnored private var feed: Task<Void, Never>?
    @ObservationIgnored private var operations:
        [SettingKey: (
            operation: OperationID, label: String, editor: Editor?,
            admission: CommandDispatchAdmission?
        )] = [:]
    @ObservationIgnored private var scheduled: Set<SettingKey> = []
    @ObservationIgnored private var editRevisions: [SettingKey: Int] = [:]
    @ObservationIgnored private var recordOperation: OperationID?

    public static let connectFirst = "Connect the camera to use its controls."
    public static let recordingUnknown = "Recording state is not known yet. Try again in a moment."

    /// `sleep` waits out the coalescing window; tests pass a manual clock.
    public init(
        coalescing: Duration = .milliseconds(120),
        sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:)
    ) {
        self.coalescing = coalescing
        self.sleep = sleep
    }


    /// A counter measured from a fresh camera-confirmed start. Initial already-recording
    /// connections have no known start; the provenance remains clockDerived.
    public private(set) var recordingElapsed: ObservedValue<Int> = .unknown
    @ObservationIgnored private var recordingStartedAt: MonotonicInstant?
    @ObservationIgnored private var recordingTicker: Task<Void, Never>?
    @ObservationIgnored private var recordingNow: @MainActor () -> MonotonicInstant = { .now() }
    @ObservationIgnored private var recordingSleep: @MainActor (Duration) async -> Void = {
        try? await Task.sleep(for: $0)
    }

    /// The existing initializer remains available; this overload supplies deterministic timing.
    public convenience init(now: @escaping @MainActor () -> MonotonicInstant,
        recordingSleep:
            @escaping @MainActor (Duration) async -> Void = hostSleepUntilCancelled(for:),
        coalescing: Duration = .milliseconds(120),
        sleep: @escaping @MainActor (Duration) async throws -> Void = hostSleep(for:)) {
        self.init(coalescing: coalescing, sleep: sleep)
        self.recordingNow = now
        self.recordingSleep = recordingSleep
    }

    private func retireRecordingElapsed() {
        recordingTicker?.cancel(); recordingTicker = nil
        recordingStartedAt = nil
        if recordingElapsed != .unknown { recordingElapsed = .unknown }
    }

    private func updateRecordingElapsed(at instant: MonotonicInstant) {
        guard let start = recordingStartedAt, instant >= start,
            let seconds = Int(exactly: (instant - start).components.seconds) else {
            retireRecordingElapsed(); return
        }
        if recordingElapsed.value != seconds {
            recordingElapsed = ObservedValue(seconds, origin: .clockDerived, at: instant,
                precision: .quantized(step: 1))
        }
    }

    private func observeRecordingElapsed(_ value: CameraSnapshot) {
        let sameOwner = latest?.session == value.session && latest?.epoch == value.epoch
        if !sameOwner { retireRecordingElapsed() }
        guard value.connection == .ready else { retireRecordingElapsed(); return }
        guard value.recording.validity == .valid else { retireRecordingElapsed(); return }
        switch value.recording.value {
        case .idle?:
            recordingTicker?.cancel(); recordingTicker = nil
            recordingStartedAt = nil
            if recordingElapsed.value != 0 {
                recordingElapsed = ObservedValue(0, origin: .clockDerived, at: recordingNow(),
                    precision: .quantized(step: 1))
            }
        case .recording?:
            guard recordingStartedAt == nil, sameOwner,
                latest?.recording.value == .idle, latest?.recording.validity == .valid else { return }
            recordingStartedAt = recordingNow()
            updateRecordingElapsed(at: recordingNow())
            let current = binding
            let wait = recordingSleep
            recordingTicker = Task { [weak self] in
                while !Task.isCancelled {
                    await wait(.seconds(1))
                    guard !Task.isCancelled, let self, self.binding == current,
                        self.recordingStartedAt != nil else { return }
                    self.updateRecordingElapsed(at: self.recordingNow())
                }
            }
        default: retireRecordingElapsed()
        }
    }

    // MARK: Binding

    /// Makes `session` the target of the controls and follows its snapshots (the only
    /// subscription). A previous binding is retired first.
    public func bind(_ session: any CameraSession) {
        unbind()
        let current = binding
        self.session = session
        feed = Task { [weak self] in
            // A native owner may already have left before this task starts. Do not touch its
            // session to create a subscription after the binding or its controls have retired.
            guard !Task.isCancelled, self?.binding == current else { return }
            for await snapshot in await session.snapshots() {
                guard let self, self.binding == current else { return }
                self.apply(snapshot)
                if case .disconnected = snapshot.connection { break }
            }
            guard let self, self.binding == current else { return }
            self.feed = nil
            self.retireRecordingElapsed()
            self.onEnded()
        }
    }

    /// Retires the binding: stops following, drops pending edits and record state, obsoletes
    /// every editor. Never closes the session and never sends a command.
    public func unbind() {
        retireRecordingElapsed()
        binding += 1
        feed?.cancel()
        feed = nil
        let changed = latest != nil || !pending.isEmpty
        rateChangeWake?.cancel()
        rateChangeWake = nil
        if frameRateSettling { frameRateSettling = false }
        session = nil
        withMutation(keyPath: \.snapshot) { latest = nil }
        if timecodeReading != .unknown { timecodeReading = .unknown }
        if timecodeTemplate != nil { timecodeTemplate = nil }
        pending = [:]
        operations = [:]
        scheduled = []
        editRevisions = [:]
        recordOperation = nil
        recordPending = false
        if changed { onChange() }
    }

    /// How long `frameRateSettling` holds after a reported frame-rate change (Kotlin twin:
    /// `RATE_CHANGE_HOLD`): the camera re-sends its speed for the new rate within it.
    public static let rateChangeHold: Duration = .seconds(3)

    /// True for `rateChangeHold` after the camera reports a new recording frame rate (one known
    /// rate replaced by another). Speeds and rates arrive from two moments around a format change,
    /// so readouts that pair them (an emulated shutter angle) hold the operator's value meanwhile.
    /// Observable: the end of the hold redraws without waiting for another snapshot.
    public private(set) var frameRateSettling = false
    @ObservationIgnored private var rateChangeWake: Task<Void, Never>?

    private func openRateChangeHold() {
        if !frameRateSettling { frameRateSettling = true }
        rateChangeWake?.cancel()
        let current = binding
        let wait = recordingSleep
        rateChangeWake = Task { [weak self] in
            await wait(Self.rateChangeHold)
            guard !Task.isCancelled, let self, self.binding == current else { return }
            self.rateChangeWake = nil
            self.frameRateSettling = false
            self.onChange()
        }
    }

    private func apply(_ snapshot: CameraSnapshot) {
        if case .frameRate(let next)? = snapshot.value(of: .frameRate).value,
            case .frameRate(let previous)? = latest?.value(of: .frameRate).value, previous != next,
            latest?.session == snapshot.session {
            openRateChangeHold()
        }
        observeRecordingElapsed(snapshot)
        if let previous = latest, Self.differsOnlyInTimecode(previous, snapshot) {
            latest = snapshot
        } else {
            withMutation(keyPath: \.snapshot) { latest = snapshot }
        }
        if timecodeReading != snapshot.timecodeReading { timecodeReading = snapshot.timecodeReading }
        let template = MonitorTimecodeFormat.label(snapshot).map(MonitorTimecodeFormat.widthTemplate)
        if timecodeTemplate != template { timecodeTemplate = template }
        onChange()
    }

    private static func differsOnlyInTimecode(_ old: CameraSnapshot, _ new: CameraSnapshot) -> Bool {
        var old = old
        old.timecodeReading = new.timecodeReading
        old.revision = new.revision
        return old == new
    }

    // MARK: Readouts

    /// The operator's pending target, else the reported value; `nil` is unknown.
    public func shown(_ key: SettingKey) -> SettingValue? {
        pending[key] ?? snapshot?.value(of: key).value
    }

    /// Camera-reported recording; `nil` while unknown (never idle).
    public var recording: RecordingState? { snapshot?.recording.value }

    /// Recording as a yes or no only when the camera reports one of the two; otherwise `nil`.
    public var isRecording: Bool? {
        switch recording {
        case .recording?: true
        case .idle?: false
        default: nil
        }
    }

    // MARK: Editing

    /// Opens an editor for `key` under the current assumptions; `nil` without a described setting.
    public func edit(_ key: SettingKey) -> Editor? {
        guard let snapshot, let descriptor = snapshot.capabilities[key] else { return nil }
        return Editor(
            key: key, binding: binding, session: snapshot.session, epoch: snapshot.epoch,
            authority: snapshot.authority, domain: descriptor.domain,
            localRevision: editRevisions[key, default: 0])
    }

    /// Whether `editor` still describes this session, epoch, authority and domain.
    public func isCurrent(_ editor: Editor) -> Bool {
        guard editor.binding == binding,
            editor.localRevision == editRevisions[editor.key, default: 0], let snapshot
        else { return false }
        return editor.session == snapshot.session && editor.epoch == snapshot.epoch
            && editor.authority == snapshot.authority
            && editor.domain == snapshot.capabilities[editor.key]?.domain
    }

    /// Sets `value` from an open editor. Refused (`false`, nothing sent) once the editor is obsolete.
    @discardableResult
    public func commit(_ value: SettingValue, from editor: Editor, label: String) -> Bool {
        guard admits(value, from: editor) else { return false }
        set(value, label: label, editor: editor, admission: nil)
        return true
    }

    @discardableResult
    public func commit(
        _ value: SettingValue, from editor: Editor, label: String,
        admission: CommandDispatchAdmission
    ) -> Bool {
        guard admits(value, from: editor) else { return false }
        set(value, label: label, editor: editor, admission: admission)
        return true
    }

    /// Retires one local setting edit and its captured editors. Already-sent camera work
    /// continues; its receipt cannot clear a successor. No command or owner epoch change.
    public func cancelEdit(_ key: SettingKey) {
        editRevisions[key, default: 0] += 1
        operations[key] = nil
        scheduled.remove(key)
        pending[key] = nil
        onChange()
    }

    private func admits(_ value: SettingValue, from editor: Editor) -> Bool {
        guard value.key == editor.key, isCurrent(editor), let snapshot,
            snapshot.connection == .ready, let descriptor = snapshot.capabilities[editor.key],
            descriptor.access == .readWrite, descriptor.availability == .available,
            descriptor.accepts(value)
        else { return false }
        switch snapshot.authority {
        case .owner, .lease: return true
        default: return false
        }
    }

    /// Shows `value` at once and sends it after the coalescing window; a newer value for the
    /// same setting replaces it. `label` names it in operator notes ("ISO 800").
    public func set(_ value: SettingValue, label: String) {
        set(value, label: label, editor: nil, admission: nil)
    }

    public func set(_ value: SettingValue, label: String, admission: CommandDispatchAdmission) {
        set(value, label: label, editor: nil, admission: admission)
    }

    private func set(
        _ value: SettingValue, label: String, editor: Editor?, admission: CommandDispatchAdmission?
    ) {
        guard session != nil else { return onNote(Self.connectFirst) }
        let key = value.key
        pending[key] = value
        operations[key] = (OperationID(), label, editor, admission)
        onChange()
        guard scheduled.insert(key).inserted else { return }
        let current = binding
        let revision = editRevisions[key, default: 0]
        // The hosted task-allocator aborts here came from the default `sleep` closure literal
        // (swiftlang/swift#92017; see `hostSleep(for:)`). Capturing `sleep` first leaves the
        // model free during the window.
        let sleep = sleep, coalescing = coalescing
        Task { [weak self] in
            try? await sleep(coalescing)
            guard let self, self.binding == current,
                self.editRevisions[key, default: 0] == revision
            else { return }
            self.scheduled.remove(key)
            self.submit(key)
        }
    }

    private func submit(_ key: SettingKey) {
        guard let (operation, label, editor, admission) = operations[key], let value = pending[key]
        else {
            return
        }
        if let editor, !admits(value, from: editor) {
            return finish(key, operation, binding, note: nil)
        }
        guard let session, let snapshot else {
            return finish(key, operation, binding, note: Self.connectFirst)
        }
        let command = CameraCommand(
            .set(value), preconditions: CommandPreconditions(snapshot), operation: operation)
        let current = binding
        Task { [weak self] in
            let receipt = await Self.finished(command, on: session, admission: admission)
            guard let self else { return }
            self.onWriteFinished(label, receipt)
            self.finish(key, operation, current, note: self.noteFor(receipt.stage, label))
        }
    }

    private func finish(_ key: SettingKey, _ operation: OperationID, _ from: Int, note: String?) {
        // A retired binding, or a newer edit of the same setting, owns the control now.
        guard from == binding, operations[key]?.operation == operation else { return }
        operations[key] = nil
        pending[key] = nil
        onChange()
        if let note { onNote(note) }
    }

    // MARK: Record

    /// Unknown recording, mode, access or control readiness cannot be confirmed.
    public func recordEditor() -> RecordEditor? {
        guard !recordPending, let snapshot else { return nil }
        return recordEditor(in: snapshot)
    }

    private func recordEditor(in snapshot: CameraSnapshot) -> RecordEditor? {
        guard snapshot.connection == .ready, let mode = snapshot.mode.value, mode.role == .video,
            let descriptor = snapshot.capabilities[.recording], descriptor.access == .readWrite,
            descriptor.availability == .available
        else { return nil }
        switch snapshot.authority {
        case .owner, .lease: break
        default: return nil
        }
        let recording: Bool
        switch snapshot.recording.value {
        case .idle?: recording = false
        case .recording?: recording = true
        default: return nil
        }
        return RecordEditor(
            recording: recording,
            editor: Editor(
                key: .recording, binding: binding, session: snapshot.session,
                epoch: snapshot.epoch, authority: snapshot.authority, domain: descriptor.domain,
                localRevision: editRevisions[.recording, default: 0]),
            mode: mode)
    }

    /// Checks mode, epoch, authority, binding, readiness and the captured recording observation.
    public func canCommitRecord(from editor: RecordEditor) -> Bool {
        guard !recordPending, let snapshot else { return false }
        return recordApprovalMatches(editor, snapshot: snapshot)
    }

    private func recordApprovalMatches(_ editor: RecordEditor, snapshot: CameraSnapshot) -> Bool {
        guard let current = recordEditor(in: snapshot),
            current.editor == editor.editor, current.mode == editor.mode
        else { return false }
        return current.recording == editor.recording
    }

    /// Sends the captured target. A fresh snapshot is checked again immediately before dispatch.
    @discardableResult public func commitRecord(from editor: RecordEditor) -> Bool {
        guard canCommitRecord(from: editor) else { return false }
        record(start: !editor.recording, approved: editor)
        return true
    }

    @discardableResult public func commitRecord(
        from editor: RecordEditor, admission: CommandDispatchAdmission
    ) -> Bool {
        guard canCommitRecord(from: editor) else { return false }
        beginRecord(start: !editor.recording, approved: editor, admission: admission)
        return true
    }

    /// Starts (`true`) or stops (`false`) recording; `nil` resolves from a fresh report (stop
    /// while recording, start while idle). Unknown sends nothing. One record operation at a time.
    public func record(start: Bool?) {
        beginRecord(start: start, approved: nil)
    }

    public func record(start: Bool?, admission: CommandDispatchAdmission) {
        beginRecord(start: start, approved: nil, admission: admission)
    }

    private func record(start: Bool?, approved: RecordEditor?) {
        beginRecord(start: start, approved: approved)
    }

    /// Waits for the same terminal receipt as `record`; nil means no operation or a retired binding.
    public func recordAndWait(start: Bool?) async -> CommandReceipt? {
        await beginRecord(start: start, approved: nil)?.value
    }

    public func recordAndWait(start: Bool?, admission: CommandDispatchAdmission) async
        -> CommandReceipt?
    {
        await beginRecord(start: start, approved: nil, admission: admission)?.value
    }

    @discardableResult private func beginRecord(
        start: Bool?, approved: RecordEditor?, admission: CommandDispatchAdmission? = nil
    ) -> Task<
        CommandReceipt?, Never
    >? {
        guard !recordPending else { return nil }
        guard let session else {
            onNote(Self.connectFirst)
            return nil
        }
        let operation = OperationID()
        let current = binding
        recordOperation = operation
        recordPending = true
        return Task { [weak self] in
            let fresh = await session.currentSnapshot()
            guard let self, self.binding == current else { return nil }
            if let approved {
                guard let fresh,
                    self.recordApprovalMatches(approved, snapshot: fresh)
                else {
                    self.finishRecord(operation, current, note: nil, receipt: nil)
                    return nil
                }
            }
            let intent: CameraCommandIntent? =
                switch (start, fresh?.recording.value) {
                case (true?, _): .startRecording
                case (false?, _): .stopRecording
                case (nil, .recording?): .stopRecording
                case (nil, .idle?): .startRecording
                default: nil
                }
            guard let intent, let fresh else {
                self.finishRecord(operation, current, note: Self.recordingUnknown, receipt: nil)
                return nil
            }
            let command = CameraCommand(
                intent, preconditions: CommandPreconditions(fresh), operation: operation)
            let receipt = await Self.finished(command, on: session, admission: admission)
            guard self.binding == current, self.recordOperation == operation else { return nil }
            self.finishRecord(
                operation, current,
                note: self.noteFor(receipt.stage, intent == .startRecording ? "Record" : "Stop"),
                receipt: receipt)
            return receipt
        }
    }

    private func finishRecord(
        _ operation: OperationID, _ from: Int, note: String?, receipt: CommandReceipt?
    ) {
        guard from == binding, recordOperation == operation else { return }
        recordOperation = nil
        recordPending = false
        if let note { onNote(note) }
        if let receipt { onRecordFinished(receipt) }
    }

    // MARK: Outcomes

    private static func finished(
        _ command: CameraCommand, on session: any CameraSession,
        admission: CommandDispatchAdmission? = nil
    ) async
        -> CommandReceipt
    {
        let receipt: CommandReceipt
        if let admission {
            receipt = await admission.dispatch(command, on: session.id)
        } else {
            receipt = await session.submit(command)
        }
        if receipt.isFinished { return receipt }
        return await session.outcome(of: command.operation) ?? receipt
    }

    /// Operator copy for an outcome that is not a confirmation; `nil` for a confirmation or a
    /// superseded write (the newer receipt carries the outcome).
    public static func note(for stage: CommandStage, _ label: String) -> String? {
        switch stage {
        case .confirmed, .failed(.superseded):
            nil
        case .rejected(.cameraRefused):
            "\(label): the camera refused it."
        case .rejected(.outOfDomain), .rejected(.unsupported), .rejected(.supportUnknown):
            "\(label) is not offered by this camera."
        case .rejected(.staleCapabilities), .rejected(.staleEpoch):
            "\(label) was not sent: the camera state changed. Try again."
        case .rejected(.unavailable(let reason)):
            reason == .mode
                ? "\(label) is not available in this mode." : "\(label) is not available right now."
        case .rejected:
            connectFirst
        case .failed(.notApplied):
            "\(label) was not applied by the camera."
        case .failed(.notSent):
            "\(label) was not sent."
        case .outcomeUnknown:
            "\(label): the camera link dropped before it confirmed."
        case .timedOut, .created, .admitted, .sent, .accepted, .awaitingObservation:
            "The camera did not confirm \(label)."
        }
    }
}
