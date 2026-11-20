#if canImport(Network)
import Foundation
import Network

/// What a stream connection reports, in order, on its own queue.
public enum StreamConnectionEvent: Equatable, Sendable {
    case opened
    case received([UInt8])
    /// A write of this many bytes reached the network stack.
    case wrote(Int)
    /// The connection failed, was refused or the peer closed it. Reported once; nothing follows.
    case lost
}

/// The socket under a stream. Production uses `NetworkStreamConnection`; tests script their own.
public protocol StreamConnection: Sendable {
    func open(onEvent: @escaping @Sendable (StreamConnectionEvent) -> Void)
    func write(_ bytes: [UInt8])
    /// Closes without reporting `.lost`.
    func close()
}

/// A connection on Network.framework: TLS for `rtmps://`, where the system trust store checks the
/// server with the host name for SNI, or plain TCP for a plain `rtmp://` destination the operator
/// chose (a Custom server only; `StreamDestination.isEncrypted` is `false`).
public final class NetworkStreamConnection: StreamConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "opencine.streaming.connection", qos: .userInitiated)
    // Touched only on `queue`.
    private var onEvent: (@Sendable (StreamConnectionEvent) -> Void)?
    private var finished = false

    /// TLS when `encrypted`, else plain TCP. Pass the destination's `isEncrypted`.
    public convenience init(host: String, port: UInt16, encrypted: Bool = true) {
        let tls = encrypted ? NWProtocolTLS.Options() : nil
        self.init(host: host, port: port, parameters: NWParameters(tls: tls, tcp: Self.tcpOptions()))
    }

    private init(host: String, port: UInt16, parameters: NWParameters) {
        connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .https, using: parameters)
    }

    private static func tcpOptions() -> NWProtocolTCP.Options {
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        options.enableKeepalive = true
        options.connectionTimeout = 15
        return options
    }

    public func open(onEvent: @escaping @Sendable (StreamConnectionEvent) -> Void) {
        queue.async { [self] in
            self.onEvent = onEvent
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    emit(.opened)
                    receive()
                case .waiting, .failed:
                    lose()
                case .cancelled:
                    lose()
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let count = bytes.count
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { lose() } else { emit(.wrote(count)) }
        })
    }

    public func close() {
        queue.async { [self] in
            finished = true
            onEvent = nil
            connection.cancel()
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { emit(.received(Array(data))) }
            if complete || error != nil {
                lose()
            } else {
                receive()
            }
        }
    }

    /// On `queue`.
    private func emit(_ event: StreamConnectionEvent) {
        guard !finished else { return }
        onEvent?(event)
    }

    /// On `queue`.
    private func lose() {
        guard !finished else { return }
        finished = true
        onEvent?(.lost)
        onEvent = nil
        connection.cancel()
    }
}
#endif
