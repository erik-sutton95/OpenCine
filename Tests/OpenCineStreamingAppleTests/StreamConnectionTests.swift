#if canImport(Network)
import Foundation
import Network
import OpenCineStreaming
import Testing

@testable import OpenCineStreamingApple

/// A local plain TCP listener that runs one scripted peer.
final class LocalPeer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "opencine.streaming.test-peer")
    private var peer: NWConnection?
    private let onRead: (@Sendable ([UInt8]) -> Void)?

    init(echo: Bool, closeAfterFirstRead: Bool = false, onRead: (@Sendable ([UInt8]) -> Void)? = nil) throws {
        self.onRead = onRead
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [unowned self] connection in
            peer = connection
            connection.start(queue: queue)
            read(connection, echo: echo, closeAfterFirstRead: closeAfterFirstRead)
        }
    }

    func start() async -> UInt16 {
        await withCheckedContinuation { (continuation: CheckedContinuation<UInt16, Never>) in
            listener.stateUpdateHandler = { [unowned self] state in
                if case .ready = state, let port = listener.port?.rawValue {
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: port)
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        peer?.cancel()
        listener.cancel()
    }

    /// Stops listening and returns once the port is closed.
    func stopListening() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                if case .cancelled = state { continuation.resume() }
            }
            listener.cancel()
        }
    }

    private func read(_ connection: NWConnection, echo: Bool, closeAfterFirstRead: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, _ in
            if let data { self?.onRead?(Array(data)) }
            if let data, echo { connection.send(content: data, completion: .idempotent) }
            if closeAfterFirstRead || complete {
                connection.cancel()
                return
            }
            self?.read(connection, echo: echo, closeAfterFirstRead: closeAfterFirstRead)
        }
    }
}

/// Collects connection events into an async sequence.
final class EventLog: @unchecked Sendable {
    let stream: AsyncStream<StreamConnectionEvent>
    private let continuation: AsyncStream<StreamConnectionEvent>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream() }

    var sink: @Sendable (StreamConnectionEvent) -> Void { { [continuation] in continuation.yield($0) } }

    /// Events up to and including the first one that matches.
    func until(_ match: (StreamConnectionEvent) -> Bool) async -> [StreamConnectionEvent] {
        var seen: [StreamConnectionEvent] = []
        for await event in stream {
            seen.append(event)
            if match(event) { break }
        }
        return seen
    }
}

@Suite(.timeLimit(.minutes(1))) struct StreamConnectionTests {
    @Test func deliversBytesBothWays() async throws {
        let peer = try LocalPeer(echo: true)
        let port = await peer.start()
        defer { peer.stop() }
        let log = EventLog()
        let connection = NetworkStreamConnection(host: "127.0.0.1", port: port, encrypted: false)
        connection.open(onEvent: log.sink)
        let opening = await log.until { $0 == .opened }
        #expect(opening == [.opened])
        connection.write([1, 2, 3])
        let events = await log.until { if case .received = $0 { true } else { false } }
        #expect(events.contains(.wrote(3)))
        #expect(events.last == .received([1, 2, 3]))
        connection.close()
    }

    @Test func reportsLostWhenPeerCloses() async throws {
        let peer = try LocalPeer(echo: false, closeAfterFirstRead: true)
        let port = await peer.start()
        defer { peer.stop() }
        let log = EventLog()
        let connection = NetworkStreamConnection(host: "127.0.0.1", port: port, encrypted: false)
        connection.open(onEvent: log.sink)
        _ = await log.until { $0 == .opened }
        connection.write([9])
        let events = await log.until { $0 == .lost }
        #expect(events.last == .lost)
        #expect(events.filter { $0 == .lost }.count == 1)
    }

    @Test func refusedConnectionIsLost() async throws {
        let peer = try LocalPeer(echo: false)
        let port = await peer.start()
        await peer.stopListening()
        let log = EventLog()
        let connection = NetworkStreamConnection(host: "127.0.0.1", port: port, encrypted: false)
        connection.open(onEvent: log.sink)
        let events = await log.until { $0 == .lost }
        #expect(events == [.lost])
    }
}

@Suite(.timeLimit(.minutes(1))) struct StreamTransportTests {
    /// A plain `rtmp://` Custom server gets the RTMP handshake in the clear (C0 is version 3); an
    /// `rtmps://` address opens TLS first (a handshake record, 0x16), whoever answers.
    @Test(arguments: [false, true]) func publisherPicksTheTransportFromTheAddress(encrypted: Bool) async throws {
        let reads = AsyncStream.makeStream(of: [UInt8].self)
        let peer = try LocalPeer(echo: false, onRead: { reads.continuation.yield($0) })
        let port = await peer.start()
        defer { peer.stop() }
        let scheme = encrypted ? "rtmps" : "rtmp"
        let publisher = StreamPublisher(
            destination: try StreamDestination(
                serverURL: "\(scheme)://127.0.0.1:\(port)/live", streamKey: "k", allowsPlainRTMP: true),
            format: MediaFixtures.format720)
        publisher.start()
        defer { publisher.stop() }
        var first: [UInt8] = []
        for await bytes in reads.stream {
            first = bytes
            break
        }
        #expect(first.first == (encrypted ? 0x16 : 0x03))
    }
}
#endif
