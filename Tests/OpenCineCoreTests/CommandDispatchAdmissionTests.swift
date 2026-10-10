import Foundation
import OpenCineCore
import Testing

/// Local queued authority has identical Swift/Kotlin scenarios; no camera or wire fixture changes.
@Suite struct CommandDispatchAdmissionTests {
    @Test func currentAdmissionDispatchesExactOperationAndRejectsWrongSessionOrEpoch() async {
        let source = CameraSessionID()
        let command = CameraCommand(
            .startRecording,
            preconditions: .init(session: source, epoch: .init(7), capabilityRevision: .init(2)))
        let port = Port()
        let admission = CommandDispatchAdmission(
            session: source, epoch: .init(7), isCurrent: { true },
            submit: { await port.submit($0) })
        let receipt = await admission.dispatch(command, on: source)
        #expect(receipt.operation == command.operation && receipt.stage == .accepted)
        #expect(await port.commands == [command])
        let wrong = await admission.dispatch(command, on: CameraSessionID())
        #expect(wrong.stage == .rejected(.wrongSession))
        var otherEpoch = command
        otherEpoch.preconditions.epoch = .init(8)
        let stale = await admission.dispatch(otherEpoch, on: source)
        #expect(stale.stage == .rejected(.staleEpoch))
        #expect(await port.commands == [command])
    }

    @Test func revokedAdmissionNeverCallsSubmissionPort() async {
        let source = CameraSessionID()
        let command = CameraCommand(
            .stopRecording,
            preconditions: .init(session: source, epoch: .init(1), capabilityRevision: .init(1)))
        let port = Port()
        let admission = CommandDispatchAdmission(
            session: source, epoch: .init(1), isCurrent: { false },
            submit: { await port.submit($0) })
        let refused = await admission.dispatch(command, on: source)
        #expect(refused.operation == command.operation)
        #expect(refused.stage == .rejected(.authorityExpired) && refused.isFinished)
        #expect(await port.commands.isEmpty)
    }

    @Test func enteredSubmissionCompletesAfterRevocation() async throws {
        let source = CameraSessionID()
        let command = CameraCommand(
            .startRecording,
            preconditions: .init(session: source, epoch: .init(1), capabilityRevision: .init(1)))
        let gate = Gate()
        let port = Port()
        let admission = CommandDispatchAdmission(
            session: source, epoch: .init(1), isCurrent: { gate.read() },
            submit: { await port.submit($0, held: true) })
        let submitting = Task { await admission.dispatch(command, on: source) }
        try #require(await entered(port))
        gate.close()
        await port.finish()
        let receipt = await submitting.value
        #expect(receipt.operation == command.operation && receipt.stage == .accepted)
        #expect(await port.commands == [command])
        let refused = await admission.dispatch(command, on: source)
        #expect(refused.stage == .rejected(.authorityExpired))
        #expect(await port.commands == [command])
    }

    private actor Port {
        var commands: [CameraCommand] = []
        private var continuation: CheckedContinuation<Void, Never>?
        var isWaiting: Bool { continuation != nil }
        func submit(_ command: CameraCommand, held: Bool = false) async -> CommandReceipt {
            commands.append(command)
            if held { await withCheckedContinuation { continuation = $0 } }
            return CommandReceipt(
                operation: command.operation, session: command.preconditions.session,
                intent: command.intent, stage: .accepted, confirmation: .acknowledgementOnly)
        }
        func finish() {
            continuation?.resume()
            continuation = nil
        }
    }
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var current = true
        func read() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return current
        }
        func close() {
            lock.lock()
            current = false
            lock.unlock()
        }
    }
    private func entered(_ port: Port) async -> Bool {
        for _ in 0..<1_000 {
            if await port.isWaiting { return true }
            await Task.yield()
        }
        return false
    }
}
