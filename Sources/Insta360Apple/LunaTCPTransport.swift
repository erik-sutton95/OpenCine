import Foundation
import Network
import OpenCineCore

@MainActor
final class LunaTCPTransport {
    var onData: ((Data) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private var connection: NWConnection?
    private var ready: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    private var generation = 0
    private let queue = DispatchQueue(label: "org.opencine.insta360.tcp", qos: .userInitiated)
    var commandSource: LunaNativeCommandSource {
        .init(transport: self, epoch: generation, endpoint: connection)
    }

    func connect(host: String, port: UInt16, localAddress: String?) async throws {
        try Task.checkCancellation()
        disconnect()
        generation += 1
        let token = generation
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        // A cellular/default internet route must not steal a camera SoftAP connection.
        if let localAddress {
            parameters.requiredLocalEndpoint = .hostPort(host: .init(localAddress), port: .any)
        }
        let connection = NWConnection(
            host: .init(host), port: .init(rawValue: port)!, using: parameters)
        self.connection = connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                ready = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        switch state {
                        case .ready:
                            self.timeout?.cancel()
                            let waiter = self.ready
                            self.ready = nil
                            waiter?.resume()
                        case .failed(let error): self.fail(error.localizedDescription)
                        case .cancelled: self.fail("The camera video connection closed.")
                        default: break
                        }
                    }
                }
                timeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(12))
                    guard !Task.isCancelled, let self, token == self.generation else { return }
                    self.fail(
                        "The camera did not answer on its Wi-Fi network. Check Local Network permission and the camera Wi-Fi connection."
                    )
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.disconnect()
            }
        }
        receive(token: token)
    }
    func send(_ data: Data) async throws {
        try await send(data, firstDispatch: nil, didDispatch: nil)
    }
    func send(
        _ data: Data, admission: LunaCommandAdmission, source: LunaNativeCommandSource,
        didDispatch: @escaping LunaCommandDidDispatch
    ) async throws {
        try admission.requireCurrent()
        guard source.admits(commandSource) else { throw LunaCommandAdmissionError.expired }
        try await send(
            data, firstDispatch: .init(admission: admission, source: source),
            didDispatch: didDispatch)
    }
    private func send(
        _ data: Data, firstDispatch supplied: LunaCommandFirstDispatch?,
        didDispatch: LunaCommandDidDispatch?
    ) async throws {
        guard let connection else {
            throw ConnectionFailure.luna(
                .linkLost, "video.closed", "The camera video connection is closed.")
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let write = {
                connection.send(
                    content: data,
                    completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    })
            }
            if var first = supplied {
                do {
                    guard let didDispatch else { throw LunaCommandAdmissionError.expired }
                    try first.perform(
                        current: { self.commandSource }, native: write, didDispatch: didDispatch)
                } catch { continuation.resume(throwing: error) }
            } else {
                write()
            }
        }
    }
    func sendBeforeClosing(_ data: Data) {
        guard let connection else { return }
        self.connection = nil
        generation += 1
        timeout?.cancel()
        connection.stateUpdateHandler = nil
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
        let waiter = ready
        ready = nil
        waiter?.resume(throwing: CancellationError())
    }
    func disconnect() {
        generation += 1
        timeout?.cancel()
        timeout = nil
        let old = connection
        connection = nil
        old?.stateUpdateHandler = nil
        old?.cancel()
        let waiter = ready
        ready = nil
        waiter?.resume(throwing: CancellationError())
    }
    private func fail(_ message: String) {
        let wasReady = ready == nil
        let waiter = ready
        ready = nil
        disconnect()
        waiter?.resume(
            throwing: ConnectionFailure.luna(
                .linkLost, "video.failed", message, phase: .negotiating))
        if wasReady { onDisconnect?(message) }
    }
    private func receive(token: Int) {
        guard let connection, generation == token else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if let data, !data.isEmpty { self.onData?(data) }
                if let error {
                    self.fail(error.localizedDescription)
                } else if complete {
                    self.fail("The camera closed its video connection.")
                } else {
                    self.receive(token: token)
                }
            }
        }
    }
}
