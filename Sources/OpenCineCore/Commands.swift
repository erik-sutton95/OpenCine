import Foundation

/// What the operator wants. Recording uses explicit start and stop: a blind toggle sent across a
/// delayed link can undo its own successful retry. A UI toggle resolves to start or stop from a
/// fresh snapshot before it becomes an intent.
public enum CameraCommandIntent: Hashable, Codable, Sendable {
    case set(SettingValue)
    case startRecording
    case stopRecording
    /// Normalized 0...1 coordinates in the displayed picture.
    case focusPoint(x: Double, y: Double)

    public var key: SettingKey {
        switch self {
        case .set(let value): value.key
        case .startRecording, .stopRecording: .recording
        case .focusPoint: .focusPoint
        }
    }
}

/// The assumptions a command was created under. Admission rejects the command when any of them
/// no longer holds, so a queued edit cannot reach a replacement link, a changed capability set or
/// a lapsed lease. Stream generation is deliberately absent: only operations that depend on one
/// picture stream need it, and none in this vocabulary do.
public struct CommandPreconditions: Hashable, Codable, Sendable {
    public var session: CameraSessionID
    public var epoch: ControlEpoch
    public var capabilityRevision: CapabilityRevision
    /// Must equal the session's current lease (`nil` for an owner).
    public var lease: ControlLeaseID?
    public var deadline: MonotonicInstant?

    public init(
        session: CameraSessionID, epoch: ControlEpoch, capabilityRevision: CapabilityRevision,
        lease: ControlLeaseID? = nil, deadline: MonotonicInstant? = nil
    ) {
        self.session = session
        self.epoch = epoch
        self.capabilityRevision = capabilityRevision
        self.lease = lease
        self.deadline = deadline
    }

    /// The assumptions of an operator looking at `snapshot` right now.
    public init(_ snapshot: CameraSnapshot, deadline: MonotonicInstant? = nil) {
        self.init(
            session: snapshot.session, epoch: snapshot.epoch,
            capabilityRevision: snapshot.capabilities.revision,
            lease: snapshot.authority.leaseID, deadline: deadline)
    }
}

public struct CameraCommand: Hashable, Codable, Sendable {
    /// Resubmitting a known operation returns its receipt and never acts twice.
    public var operation: OperationID
    public var intent: CameraCommandIntent
    public var preconditions: CommandPreconditions

    public init(
        _ intent: CameraCommandIntent, preconditions: CommandPreconditions,
        operation: OperationID = OperationID()
    ) {
        self.operation = operation
        self.intent = intent
        self.preconditions = preconditions
    }
}

public enum CommandRejection: Hashable, Codable, Sendable {
    case sessionClosed
    case wrongSession
    case notConnected
    case staleEpoch
    case deadlinePassed
    case noAuthority
    case authorityExpired
    case staleCapabilities
    case supportUnknown
    case unsupported
    case readOnly
    case unavailable(UnavailableReason)
    case outOfDomain
    /// The adapter cannot express the intent safely without knowing the reported state, for
    /// example when its wire command is a toggle.
    case recordingStateUnknown
    /// The camera refused the command (protocol NACK).
    case cameraRefused
}

public enum CommandFailure: Hashable, Codable, Sendable {
    /// The camera accepted, but its readback shows the value did not change.
    case notApplied
    /// The command never left the device.
    case notSent
    /// A newer write to the same setting replaced this one before its outcome was known. The
    /// camera may or may not have acted on it; the newer operation's receipt carries the outcome.
    case superseded
}

/// ```text
/// created -> admitted -> sent -> accepted -> awaitingObservation -> confirmed
///               \-> rejected      \-> failed / timedOut / outcomeUnknown
/// ```
/// Not every protocol has every stage. `accepted` means the protocol took the request, not that
/// the camera reports the new value. `outcomeUnknown` means the camera may have acted but the
/// link was lost. A timeout never manufactures a reported state.
public enum CommandStage: Hashable, Codable, Sendable {
    case created
    case admitted
    case sent
    case accepted
    case awaitingObservation
    case confirmed
    case rejected(CommandRejection)
    case failed(CommandFailure)
    case timedOut
    case outcomeUnknown

    public var isTerminal: Bool {
        switch self {
        case .created, .admitted, .sent, .accepted, .awaitingObservation: false
        case .confirmed, .rejected, .failed, .timedOut, .outcomeUnknown: true
        }
    }
}

/// Progress of one operation, tracked by `OperationID` apart from the snapshot feed.
public struct CommandReceipt: Hashable, Codable, Sendable {
    public var operation: OperationID
    public var session: CameraSessionID
    public var intent: CameraCommandIntent
    public var stage: CommandStage
    /// From the setting's semantics at submission.
    public var confirmation: SettingSemantics.Confirmation

    public init(
        operation: OperationID, session: CameraSessionID, intent: CameraCommandIntent,
        stage: CommandStage = .created, confirmation: SettingSemantics.Confirmation = .readback
    ) {
        self.operation = operation
        self.session = session
        self.intent = intent
        self.stage = stage
        self.confirmation = confirmation
    }

    /// Terminal, or accepted where the camera only acknowledges.
    public var isFinished: Bool {
        stage.isTerminal || (stage == .accepted && confirmation == .acknowledgementOnly)
    }
}

extension CameraSnapshot {
    /// The shared admission rule: why `command` cannot run against this snapshot at `now`, or
    /// `nil` when it may. Integrations apply it at submission (a control enabled a second ago is
    /// not authorization now) and add their own protocol rules after it. Multicam can use it to
    /// evaluate group eligibility without knowing the integration.
    public func rejection(of command: CameraCommand, at now: MonotonicInstant) -> CommandRejection? {
        let expected = command.preconditions
        if case .disconnected = connection { return .sessionClosed }
        if expected.session != session { return .wrongSession }
        if connection != .ready { return .notConnected }
        if expected.epoch != epoch { return .staleEpoch }
        if let deadline = expected.deadline, now >= deadline { return .deadlinePassed }
        if expected.lease != authority.leaseID { return .noAuthority }
        switch authority {
        case .owner: break
        case .lease(let lease):
            if let expiry = lease.expiresAt, now >= expiry { return .authorityExpired }
        case .readOnly, .unavailable: return .noAuthority
        }
        if expected.capabilityRevision != capabilities.revision { return .staleCapabilities }

        let key = command.intent.key
        guard let descriptor = capabilities[key] else {
            return capabilities.unsupported.contains(key) ? .unsupported : .supportUnknown
        }
        if descriptor.access == .readOnly { return .readOnly }
        if case .unavailable(let reason) = descriptor.availability { return .unavailable(reason) }
        switch command.intent {
        case .set(let value):
            if !descriptor.accepts(value) { return .outOfDomain }
        case .focusPoint(let x, let y):
            if !(0...1).contains(x) || !(0...1).contains(y) { return .outOfDomain }
        case .startRecording, .stopRecording:
            break
        }
        return nil
    }
}
