import Foundation

/// One queued operation's captured authority and integration-owned submission port.
/// This is local lifetime evidence, never part of a camera command or a wire encoding.
public struct CommandDispatchAdmission: Sendable {
    public let session: CameraSessionID
    public let epoch: ControlEpoch
    private let current: @Sendable () -> Bool
    private let submit: @Sendable (CameraCommand) async -> CommandReceipt

    /// The port submits to this exact session and propagates its authority to native queues.
    public init(
        session: CameraSessionID, epoch: ControlEpoch,
        isCurrent: @escaping @Sendable () -> Bool,
        submit: @escaping @Sendable (CameraCommand) async -> CommandReceipt
    ) {
        self.session = session
        self.epoch = epoch
        current = isCurrent
        self.submit = submit
    }

    public func rejection(of command: CameraCommand, on target: CameraSessionID)
        -> CommandRejection?
    {
        guard target == session, command.preconditions.session == session else {
            return .wrongSession
        }
        guard command.preconditions.epoch == epoch else { return .staleEpoch }
        return current() ? nil : .authorityExpired
    }

    /// A local refusal is terminal and has not been submitted to the session. Once the port
    /// accepts work, its original completion/outcome remains authoritative after retirement.
    public func dispatch(_ command: CameraCommand, on target: CameraSessionID) async
        -> CommandReceipt
    {
        if let rejection = rejection(of: command, on: target) {
            return CommandReceipt(
                operation: command.operation, session: target, intent: command.intent,
                stage: .rejected(rejection))
        }
        return await submit(command)
    }
}
