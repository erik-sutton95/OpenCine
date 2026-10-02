import Foundation
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
    }

    /// An explicit record confirmation authorizes exactly this camera state.
    public struct RecordEditor: Hashable, Sendable {
        public let recording: Bool
        let editor: Editor
        let mode: CaptureMode
    }

    /// The session the controls drive; `nil` when nothing is bound.
    public private(set) var session: (any CameraSession)?
    /// The latest snapshot of `session`.
    public private(set) var snapshot: CameraSnapshot?
    /// Operator targets whose operations are unfinished.
    public private(set) var pending: [SettingKey: SettingValue] = [:]
    /// A record start or stop is in flight.
    public private(set) var recordPending = false

    /// Operator copy for an outcome that is not a confirmation (and for refusing to send).
    @ObservationIgnored public var onNote: (String) -> Void = { _ in }
    /// A record operation finished (any stage), for the app's follow-up (refresh media).
    @ObservationIgnored public var onRecordFinished: (CommandReceipt) -> Void = { _ in }
    /// The reported state or a pending target changed: for projections that still copy it.
    @ObservationIgnored public var onChange: () -> Void = {}
    /// The bound session reported `.disconnected` or ended its snapshots. Called once per binding.
    @ObservationIgnored var onEnded: () -> Void = {}

    @ObservationIgnored private let coalescing: Duration
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
    @ObservationIgnored private var binding = 0
    @ObservationIgnored private var feed: Task<Void, Never>?
    @ObservationIgnored private var operations: [SettingKey: (operation: OperationID, label: String, editor: Editor?)] = [:]
    @ObservationIgnored private var scheduled: Set<SettingKey> = []
    @ObservationIgnored private var recordOperation: OperationID?

    public static let connectFirst = "Connect the camera to use its controls."
    public static let recordingUnknown = "Recording state is not known yet. Try again in a moment."

    /// `sleep` waits out the coalescing window; tests pass a manual clock.
    public init(
        coalescing: Duration = .milliseconds(120),
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.coalescing = coalescing
        self.sleep = sleep
    }

    // MARK: Binding

    /// Makes `session` the target of the controls and follows its snapshots (the only
    /// subscription). A previous binding is retired first.
    public func bind(_ session: any CameraSession) {
        unbind()
        let current = binding
        self.session = session
        feed = Task { [weak self] in
            for await snapshot in await session.snapshots() {
                guard let self, self.binding == current else { return }
                self.apply(snapshot)
                if case .disconnected = snapshot.connection { break }
            }
            guard let self, self.binding == current else { return }
            self.feed = nil
            self.onEnded()
        }
    }

    /// Retires the binding: stops following, drops pending edits and record state, obsoletes
    /// every editor. Never closes the session and never sends a command.
    public func unbind() {
        binding += 1
        feed?.cancel()
        feed = nil
        let changed = snapshot != nil || !pending.isEmpty
        session = nil
        snapshot = nil
        pending = [:]
        operations = [:]
        scheduled = []
        recordOperation = nil
        recordPending = false
        if changed { onChange() }
    }

    private func apply(_ snapshot: CameraSnapshot) {
        self.snapshot = snapshot
        onChange()
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
            authority: snapshot.authority, domain: descriptor.domain)
    }

    /// Whether `editor` still describes this session, epoch, authority and domain.
    public func isCurrent(_ editor: Editor) -> Bool {
        guard editor.binding == binding, let snapshot else { return false }
        return editor.session == snapshot.session && editor.epoch == snapshot.epoch
            && editor.authority == snapshot.authority
            && editor.domain == snapshot.capabilities[editor.key]?.domain
    }

    /// Sets `value` from an open editor. Refused (`false`, nothing sent) once the editor is obsolete.
    @discardableResult
    public func commit(_ value: SettingValue, from editor: Editor, label: String) -> Bool {
        guard admits(value, from: editor) else { return false }
        set(value, label: label, editor: editor)
        return true
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
        set(value, label: label, editor: nil)
    }

    private func set(_ value: SettingValue, label: String, editor: Editor?) {
        guard session != nil else { return onNote(Self.connectFirst) }
        let key = value.key
        pending[key] = value
        operations[key] = (OperationID(), label, editor)
        onChange()
        guard scheduled.insert(key).inserted else { return }
        let current = binding
        Task { [weak self] in
            guard let self else { return }
            await self.sleep(self.coalescing)
            guard self.binding == current else { return }
            self.scheduled.remove(key)
            self.submit(key)
        }
    }

    private func submit(_ key: SettingKey) {
        guard let (operation, label, editor) = operations[key], let value = pending[key] else { return }
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
            let receipt = await Self.finished(command, on: session)
            self?.finish(key, operation, current, note: Self.note(for: receipt.stage, label))
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
            editor: Editor(key: .recording, binding: binding, session: snapshot.session,
                epoch: snapshot.epoch, authority: snapshot.authority, domain: descriptor.domain),
            mode: mode)
    }

    /// Approval is retired on mode, epoch, authority, binding or recording changes.
    @discardableResult public func commitRecord(from editor: RecordEditor) -> Bool {
        guard recordEditor() == editor else { return false }
        record(start: !editor.recording, approved: editor)
        return true
    }

    /// Starts (`true`) or stops (`false`) recording; `nil` resolves from a fresh report (stop
    /// while recording, start while idle). Unknown sends nothing. One record operation at a time.
    public func record(start: Bool?) {
        beginRecord(start: start, approved: nil)
    }

    private func record(start: Bool?, approved: RecordEditor?) {
        beginRecord(start: start, approved: approved)
    }

    /// Waits for the same terminal receipt as `record`; nil means no operation or a retired binding.
    public func recordAndWait(start: Bool?) async -> CommandReceipt? {
        await beginRecord(start: start, approved: nil)?.value
    }

    @discardableResult private func beginRecord(start: Bool?, approved: RecordEditor?) -> Task<CommandReceipt?, Never>? {
        guard !recordPending else { return nil }
        guard let session else { onNote(Self.connectFirst); return nil }
        let operation = OperationID()
        let current = binding
        recordOperation = operation
        recordPending = true
        return Task { [weak self] in
            let fresh = await session.currentSnapshot()
            guard let self, self.binding == current else { return nil }
            if let approved {
                guard let fresh,
                    self.recordEditor(in: fresh) == approved
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
            let command = CameraCommand(intent, preconditions: CommandPreconditions(fresh), operation: operation)
            let receipt = await Self.finished(command, on: session)
            guard self.binding == current, self.recordOperation == operation else { return nil }
            self.finishRecord(
                operation, current, note: Self.note(for: receipt.stage, intent == .startRecording ? "Record" : "Stop"),
                receipt: receipt)
            return receipt
        }
    }

    private func finishRecord(_ operation: OperationID, _ from: Int, note: String?, receipt: CommandReceipt?) {
        guard from == binding, recordOperation == operation else { return }
        recordOperation = nil
        recordPending = false
        if let note { onNote(note) }
        if let receipt { onRecordFinished(receipt) }
    }

    // MARK: Outcomes

    private static func finished(_ command: CameraCommand, on session: any CameraSession) async -> CommandReceipt {
        let receipt = await session.submit(command)
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
            reason == .mode ? "\(label) is not available in this mode." : "\(label) is not available right now."
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
