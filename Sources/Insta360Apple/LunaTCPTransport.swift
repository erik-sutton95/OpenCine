import Foundation
import Network
import OpenCineCore

@MainActor
final class LunaTCPTransport {
    /// Native opening and its deadline vary independently from camera command/source ownership.
    struct Opening {
        var start: (NWConnection, @escaping @MainActor (NWConnection.State) -> Void) -> Void
        var sleep: (Duration) async throws -> Void
    }
    private let opening: Opening?
    init(opening: Opening? = nil) { self.opening = opening }

    var onData: ((Data) -> Void)?
    var onDisconnect: ((String) -> Void)?
    private var connection: NWConnection?
    private var ready: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?
    /// Ends 12 s after the camera network became reachable; a denial is named from then on.
    private var denialWindow: Task<Void, Never>?
    private var denialWindowOver = false
    private var generation = 0
    private var permission = CameraNetworkPermissionObservation()
    private var permissionAttempt: UUID?
    private let queue = DispatchQueue(label: "org.opencine.insta360.tcp", qos: .userInitiated)
    var commandSource: LunaNativeCommandSource {
        .init(transport: self, epoch: generation, endpoint: connection)
    }

    /// `reachableFor` is how long the camera network has already been reachable (the phone holds
    /// its camera address) when this connect starts. An explicit Local Network denial is named 12 s
    /// after the network became reachable (at once when that is already past), so a Settings grant
    /// in that window still wins; any other wait keeps its own 12 s from this connect.
    func connect(
        host: String, port: UInt16, localAddress: String?, reachableFor: Duration = .zero
    ) async throws {
        try Task.checkCancellation()
        disconnect()
        generation += 1
        let token = generation
        let observation = permission.begin()
        permissionAttempt = observation
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
                let stateChanged: @MainActor (NWConnection.State) -> Void = { [weak self] state in
                    guard let self, self.generation == token else { return }
                    switch state {
                    case .ready:
                        self.timeout?.cancel()
                        self.denialWindow?.cancel()
                        let waiter = self.ready
                        self.ready = nil
                        waiter?.resume()
                    case .waiting(let error):
                        let dnsCode: Int32?
                        if case .dns(let code) = error { dnsCode = code } else { dnsCode = nil }
                        if CameraNetworkPermissionPolicy.isLocalNetworkDenied(
                            dnsErrorCode: dnsCode,
                            pathDenied: connection.currentPath?.unsatisfiedReason == .localNetworkDenied)
                        {
                            self.permission.observe(.policyDenied, attempt: observation)
                            if self.denialWindowOver { self.failDenied() }
                        }
                    case .failed(let error): self.fail(error.localizedDescription)
                    case .cancelled: self.fail("The camera video connection closed.")
                    default: break
                    }
                }
                if let opening {
                    opening.start(connection, stateChanged)
                } else {
                    connection.stateUpdateHandler = { state in
                        Task { @MainActor in stateChanged(state) }
                    }
                }
                let window = Self.deadline - reachableFor
                denialWindowOver = window <= .zero
                if window > .zero, window < Self.deadline {
                    denialWindow = Task { [weak self, opening] in
                        if let opening { try? await opening.sleep(window) }
                        else { try? await Task.sleep(for: window) }
                        guard !Task.isCancelled, let self, token == self.generation else { return }
                        self.denialWindowOver = true
                        if self.permission.state == .denied { self.failDenied() }
                    }
                }
                timeout = Task { [weak self, opening] in
                    if let opening { try? await opening.sleep(Self.deadline) }
                    else { try? await Task.sleep(for: Self.deadline) }
                    guard !Task.isCancelled, let self, token == self.generation else { return }
                    if self.permission.state == .denied {
                        self.failDenied()
                    } else {
                        self.fail(
                            "The camera did not answer on its Wi-Fi network. Check Local Network permission and the camera Wi-Fi connection.")
                    }
                }
                if opening == nil { connection.start(queue: queue) }
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
        if let permissionAttempt { permission.retire(attempt: permissionAttempt) }
        permissionAttempt = nil
        generation += 1
        timeout?.cancel()
        timeout = nil
        denialWindow?.cancel()
        denialWindow = nil
        denialWindowOver = false
        let old = connection
        connection = nil
        old?.stateUpdateHandler = nil
        old?.cancel()
        let waiter = ready
        ready = nil
        waiter?.resume(throwing: CancellationError())
    }
    private static let deadline = Duration.seconds(12)

    private func failDenied() {
        fail(.luna(
            .permission(.localNetwork), "local-network.denied",
            "Local Network access is off. Enable it in Settings, then connect again.",
            phase: .negotiating, actions: [.openSettings, .retry]))
    }

    private func fail(_ message: String) {
        fail(.luna(.linkLost, "video.failed", message, phase: .negotiating))
    }
    private func fail(_ failure: ConnectionFailure) {
        let wasReady = ready == nil
        let waiter = ready
        ready = nil
        disconnect()
        waiter?.resume(throwing: failure)
        if wasReady { onDisconnect?(failure.message) }
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
