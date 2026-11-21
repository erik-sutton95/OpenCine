#if canImport(Network)
import Foundation
import Network
import OpenCineStreaming

/// A plain RTMP listener on this device, so a camera on the same network (or on this device's
/// hotspot) can publish its own stream here. It runs `RTMPReceiveSession` for one publisher at a
/// time, accepting only the session's token as the stream key; a new publisher replaces the
/// current one (a camera that reconnects). Events arrive on the receiver's own serial queue.
public final class RTMPLocalReceiver: @unchecked Sendable {
    public enum Event: Sendable {
        case listening(port: UInt16)
        case listenFailed(String)
        case publisherConnected(remote: String)
        case publisherDisconnected(remote: String, reason: String)
        case session(RTMPReceiveEvent)
    }

    public let port: UInt16
    private let token: StreamReceiverToken
    public let queue = DispatchQueue(label: "opencine.streaming.rtmp-receiver", qos: .userInteractive)
    private let onEvent: @Sendable (Event) -> Void
    // Touched only on `queue`.
    private var listener: NWListener?
    private var connection: NWConnection?
    private var session: RTMPReceiveSession
    private var remote = ""

    public init(port: UInt16 = 1935, token: StreamReceiverToken, onEvent: @escaping @Sendable (Event) -> Void) {
        self.port = port
        self.token = token
        session = RTMPReceiveSession(expectedStreamKey: token.value)
        self.onEvent = onEvent
    }

    public func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let tcp = NWProtocolTCP.Options()
                tcp.noDelay = true
                let parameters = NWParameters(tls: nil, tcp: tcp)
                parameters.allowLocalEndpointReuse = true
                let created = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? 1935)
                created.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: onEvent(.listening(port: created.port?.rawValue ?? port))
                    case .failed(let error): onEvent(.listenFailed("\(error)"))
                    case .waiting(let error): onEvent(.listenFailed("waiting: \(error)"))
                    default: break
                    }
                }
                created.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                created.start(queue: queue)
                listener = created
            } catch {
                onEvent(.listenFailed("\(error)"))
            }
        }
    }

    /// Closes the publisher and the listener. Events may still arrive for work already queued.
    public func stop() {
        queue.async { [self] in
            connection?.cancel()
            connection = nil
            listener?.cancel()
            listener = nil
        }
    }

    private func accept(_ next: NWConnection) {
        if let old = connection {
            old.cancel()
            onEvent(.publisherDisconnected(remote: remote, reason: "replaced by a new publisher"))
        }
        connection = next
        session = RTMPReceiveSession(expectedStreamKey: token.value)
        remote = "\(next.endpoint)"
        let name = remote
        next.stateUpdateHandler = { [weak self, weak next] state in
            guard let self, let next, connection === next else { return }
            switch state {
            case .ready:
                onEvent(.publisherConnected(remote: name))
                receive(on: next)
            case .failed(let error):
                drop(next, reason: "failed: \(error)")
            case .cancelled:
                break
            default:
                break
            }
        }
        next.start(queue: queue)
    }

    private func receive(on current: NWConnection) {
        current.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self, weak current] data, _, complete, error in
            guard let self, let current, connection === current else { return }
            if let data, !data.isEmpty {
                let output = session.receive([UInt8](data))
                if !output.outbound.isEmpty {
                    current.send(content: Data(output.outbound), completion: .contentProcessed { _ in })
                }
                for event in output.events { onEvent(.session(event)) }
                if session.state == .closed { return drop(current, reason: "session closed") }
            }
            if complete { return drop(current, reason: "publisher closed the connection") }
            if let error { return drop(current, reason: "\(error)") }
            receive(on: current)
        }
    }

    private func drop(_ current: NWConnection, reason: String) {
        guard connection === current else { return }
        current.cancel()
        connection = nil
        onEvent(.publisherDisconnected(remote: remote, reason: reason))
    }
}
#endif
