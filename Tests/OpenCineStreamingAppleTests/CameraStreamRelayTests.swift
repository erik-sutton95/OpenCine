#if canImport(Network) && canImport(VideoToolbox) && os(macOS)
import AVFoundation
import CoreVideo
import Foundation
import Network
import OpenCineStreaming
import OpenCineStreamingApple
import Testing

/// The relay over a real loopback socket: a recorded publisher (`Fixtures/rtmp-receive/`) is
/// written to the listener, and the relay must say when the camera connected, when its first
/// picture decoded, and when it went away, with pictures and sound in between.
@Suite(.serialized) struct CameraStreamRelayTests {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var events: [CameraStreamRelay.Event] = []
        var pictures = 0
        var sound = 0
        let listening = DispatchSemaphore(value: 0)
        let firstPicture = DispatchSemaphore(value: 0)
        let lost = DispatchSemaphore(value: 0)

        func add(_ event: CameraStreamRelay.Event) {
            lock.withLock { events.append(event) }
            switch event {
            case .listening: listening.signal()
            case .firstPicture: firstPicture.signal()
            case .lost: lost.signal()
            default: break
            }
        }
    }

    @Test(arguments: RTMPReceiveFixtures.names)
    func aPublisherConnectsShowsPicturesAndLeaves(name: String) throws {
        let box = Box()
        let port = UInt16.random(in: 40000...50000)
        let relay = CameraStreamRelay(
            port: port, token: StreamReceiverToken(value: RTMPReceiveFixtures.key),
            video: { _ in box.lock.withLock { box.pictures += 1 } },
            audio: { _ in box.lock.withLock { box.sound += 1 } },
            events: { box.add($0) })
        relay.start()
        defer { relay.stop() }
        #expect(box.listening.wait(timeout: .now() + 5) == .success)

        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: DispatchQueue(label: "camera-stream-relay-test"))
        connection.send(content: Data(try RTMPReceiveFixtures.bytes(name)), completion: .idempotent)
        #expect(box.firstPicture.wait(timeout: .now() + 10) == .success)
        connection.cancel()
        #expect(box.lost.wait(timeout: .now() + 10) == .success)

        box.lock.lock()
        defer { box.lock.unlock() }
        #expect(box.events == [.listening, .connected, .firstPicture, .lost])
        #expect(box.pictures > 0)
        #expect(box.sound > 0)
    }

    @Test func aPublisherWithTheWrongKeyIsNeverConnected() throws {
        let box = Box()
        let port = UInt16.random(in: 40000...50000)
        let relay = CameraStreamRelay(
            port: port, token: StreamReceiverToken.random(), video: { _ in }, audio: { _ in },
            events: { box.add($0) })
        relay.start()
        defer { relay.stop() }
        #expect(box.listening.wait(timeout: .now() + 5) == .success)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let closed = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "camera-stream-relay-test")
        connection.start(queue: queue)
        connection.send(content: Data(try RTMPReceiveFixtures.bytes("h264-aac")), completion: .idempotent)
        // The relay drops the publisher: reading ends, and nothing but listening is ever reported.
        @Sendable func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { _, _, complete, error in
                if complete || error != nil { closed.signal() } else { read() }
            }
        }
        read()
        #expect(closed.wait(timeout: .now() + 10) == .success)
        connection.cancel()
        box.lock.lock()
        defer { box.lock.unlock() }
        #expect(box.events == [.listening])
        #expect(box.pictures == 0)
    }
}
#endif
