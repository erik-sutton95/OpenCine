#if canImport(Network)
import Foundation
import Network
import OpenCineStreaming

/// A plain RTMP listener on this device, so a camera on the same network (or on this device's
/// hotspot) can publish its own stream here. Each connection runs its own `RTMPReceiveSession`
/// as a candidate; only one that publishes under the session's token becomes the publisher (and
/// replaces an earlier one: a camera that reconnects). A candidate that has not published within
/// 10 seconds is closed, at most 4 wait at once, and cellular interfaces are never listened on, so a
/// stranger cannot displace the camera. Events arrive on the receiver's own serial queue.
public final class RTMPLocalReceiver: @unchecked Sendable {
    public enum Event: Sendable {
        case listening(port: UInt16)
        case listenFailed(String)
        /// A connection published under the token and is now the publisher.
        case publisherConnected(remote: String)
        case publisherDisconnected(remote: String, reason: String)
        /// The publisher's session events (a candidate's are never reported).
        case session(RTMPReceiveEvent)
    }

    static let maximumCandidates = 4
    static let publishWindow: DispatchTimeInterval = .seconds(10)

    /// One connection; touched only on `queue`.
    private final class Peer: @unchecked Sendable {
        let connection: NWConnection
        let remote: String
        var session: RTMPReceiveSession

        init(_ connection: NWConnection, key: String) {
            self.connection = connection
            remote = "\(connection.endpoint)"
            session = RTMPReceiveSession(expectedStreamKey: key)
        }
    }

    public let port: UInt16
    private let token: StreamReceiverToken
    public let queue = DispatchQueue(label: "opencine.streaming.rtmp-receiver", qos: .userInteractive)
    private let onEvent: @Sendable (Event) -> Void
    // Touched only on `queue`.
    private var listener: NWListener?
    private var publisher: Peer?
    private var candidates: [Peer] = []

    public init(port: UInt16 = 1935, token: StreamReceiverToken, onEvent: @escaping @Sendable (Event) -> Void) {
        self.port = port
        self.token = token
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
                parameters.prohibitedInterfaceTypes = [.cellular]
                let created = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? 1935)
                created.stateUpdateHandler = { [weak self, weak created] state in
                    guard let self else { return }
                    switch state {
                    case .ready: onEvent(.listening(port: created?.port?.rawValue ?? port))
                    case .failed(let error):
                        created?.cancel()
                        if listener === created { listener = nil }
                        onEvent(.listenFailed("\(error)"))
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

    /// Closes every connection and the listener. Events may still arrive for work already queued.
    public func stop() {
        queue.async { [self] in
            publisher?.connection.cancel()
            publisher = nil
            for candidate in candidates { candidate.connection.cancel() }
            candidates = []
            listener?.cancel()
            listener = nil
        }
    }

    private func accept(_ next: NWConnection) {
        guard candidates.count < Self.maximumCandidates else { return next.cancel() }
        let peer = Peer(next, key: token.value)
        candidates.append(peer)
        next.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .ready: receive(peer)
            case .failed(let error): drop(peer, reason: "failed: \(error)")
            default: break
            }
        }
        queue.asyncAfter(deadline: .now() + Self.publishWindow) { [weak self, weak peer] in
            guard let self, let peer, candidates.contains(where: { $0 === peer }) else { return }
            drop(peer, reason: "did not publish in time")
        }
        next.start(queue: queue)
    }

    private func receive(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self, weak peer] data, _, complete, error in
            guard let self, let peer, publisher === peer || candidates.contains(where: { $0 === peer }) else { return }
            if let data, !data.isEmpty {
                let output = peer.session.receive([UInt8](data))
                if !output.outbound.isEmpty {
                    peer.connection.send(content: Data(output.outbound), completion: .contentProcessed { _ in })
                }
                for event in output.events {
                    if publisher !== peer, case .publish = event { promote(peer) }
                    if publisher === peer { onEvent(.session(event)) }
                }
                if peer.session.state == .closed { return drop(peer, reason: "session closed") }
            }
            if complete { return drop(peer, reason: "publisher closed the connection") }
            if let error { return drop(peer, reason: "\(error)") }
            receive(peer)
        }
    }

    /// A candidate published under the key: it becomes the publisher, replacing any earlier one.
    private func promote(_ peer: Peer) {
        candidates.removeAll { $0 === peer }
        if let old = publisher {
            old.connection.cancel()
            onEvent(.publisherDisconnected(remote: old.remote, reason: "replaced by a new publisher"))
        }
        publisher = peer
        onEvent(.publisherConnected(remote: peer.remote))
    }

    private func drop(_ peer: Peer, reason: String) {
        peer.connection.cancel()
        if publisher === peer {
            publisher = nil
            onEvent(.publisherDisconnected(remote: peer.remote, reason: reason))
        } else {
            candidates.removeAll { $0 === peer }
        }
    }
}
#endif
