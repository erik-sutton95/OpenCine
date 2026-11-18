#if canImport(VideoToolbox) && canImport(Network)
import Foundation
import OpenCineCore
import Testing

@testable import OpenCineStreaming
@testable import OpenCineStreamingApple

/// A connection the test opens, feeds and inspects by hand.
final class ScriptedConnection: StreamConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (StreamConnectionEvent) -> Void)?
    private var written: [[UInt8]] = []
    private(set) var closed = false

    var writes: [[UInt8]] { lock.withLock { written } }

    func open(onEvent: @escaping @Sendable (StreamConnectionEvent) -> Void) { lock.withLock { handler = onEvent } }
    func write(_ bytes: [UInt8]) { lock.withLock { written.append(bytes) } }
    func close() { lock.withLock { closed = true } }
    func send(_ event: StreamConnectionEvent) { lock.withLock { handler }?(event) }
}

/// Hands out scripted connections and remembers where each one went.
final class ConnectionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [(host: String, port: UInt16, connection: ScriptedConnection)] = []
    var connections: [(host: String, port: UInt16, connection: ScriptedConnection)] { lock.withLock { made } }
    var make: @Sendable (String, UInt16) -> any StreamConnection {
        { [self] host, port in
            let connection = ScriptedConnection()
            lock.withLock { made.append((host, port, connection)) }
            return connection
        }
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = MonotonicInstant.zero
    var now: MonotonicInstant {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@Suite struct StreamPublisherTests {
    private func publisher(_ factory: ConnectionFactory, _ clock: Clock) throws -> StreamPublisher {
        StreamPublisher(
            destination: try StreamDestination(serverURL: "rtmps://live.example.com/app", streamKey: "SECRETKEY"),
            format: MediaFixtures.format720, fitting: .fit, connection: factory.make, now: { clock.now },
            drivesTimers: false)
    }

    @Test func appliesActionsInOrder() throws {
        let factory = ConnectionFactory()
        let clock = Clock()
        let publisher = try publisher(factory, clock)
        publisher.start()
        _ = publisher.status
        let made = try #require(factory.connections.first)
        #expect(made.host == "live.example.com" && made.port == 443)
        made.connection.send(.opened)
        _ = publisher.status
        #expect(made.connection.writes.first?.count == 1537)  // C0 and C1
        #expect(made.connection.writes.first?.first == 0x03)
    }

    @Test func lostConnectionWaitsToReconnect() throws {
        let factory = ConnectionFactory()
        let clock = Clock()
        let publisher = try publisher(factory, clock)
        publisher.start()
        _ = publisher.status
        factory.connections[0].connection.send(.lost)
        #expect(publisher.status.phase == .reconnecting(attempt: 1))
        #expect(publisher.status.health == .offline)
        clock.now = .zero + .seconds(1)
        publisher.perform { $0.tick(at: .zero + .seconds(1)) }
        #expect(factory.connections.count == 2)
        // Events from the first connection no longer count.
        factory.connections[0].connection.send(.opened)
        _ = publisher.status
        #expect(factory.connections[0].connection.writes.isEmpty)
    }

    @Test func stopEndsTheRun() throws {
        let factory = ConnectionFactory()
        let clock = Clock()
        let publisher = try publisher(factory, clock)
        let statuses = StatusLog()
        publisher.onStatus(statuses.add)
        publisher.start()
        publisher.stop()
        #expect(publisher.status.phase == .ended(.stopped))
        #expect(factory.connections.first?.connection.closed == true)
        #expect(statuses.all.last?.phase == .ended(.stopped))
        #expect(!"\(statuses.all)".contains("SECRETKEY"))
    }

    @Test func framesWaitUntilLive() throws {
        let factory = ConnectionFactory()
        let clock = Clock()
        let publisher = try publisher(factory, clock)
        publisher.start()
        publisher.submitVideo(MediaFixtures.solid(width: 640, height: 360, (0, 0, 255)))
        publisher.perform { $0.emitFrame(at: .zero + .milliseconds(33)) }
        _ = publisher.status
        #expect(factory.connections.first?.connection.writes.isEmpty == true)
    }
}

final class StatusLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [StreamRun.Status] = []
    var all: [StreamRun.Status] { lock.withLock { stored } }
    var add: @Sendable (StreamRun.Status) -> Void { { [self] status in lock.withLock { stored.append(status) } } }
}
#endif
