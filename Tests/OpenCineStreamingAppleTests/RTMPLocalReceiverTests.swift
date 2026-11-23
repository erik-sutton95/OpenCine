#if canImport(Network) && os(macOS)
import Foundation
import Network
import OpenCineStreaming
import OpenCineStreamingApple
import Testing

/// The listener over loopback: only a connection that publishes under the key becomes the
/// publisher, so a stranger (a port scan, a wrong key, a silent socket) never displaces the camera.
@Suite(.serialized) struct RTMPLocalReceiverTests {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var events: [String] = []
        var frames = 0
        let listening = DispatchSemaphore(value: 0)
        let published = DispatchSemaphore(value: 0)
        let gone = DispatchSemaphore(value: 0)
        let frame = DispatchSemaphore(value: 0)

        func add(_ event: RTMPLocalReceiver.Event) {
            lock.withLock {
                switch event {
                case .listening: events.append("listening"); listening.signal()
                case .publisherConnected: events.append("connected")
                case .publisherDisconnected: events.append("disconnected"); gone.signal()
                case .session(.publish): events.append("publish"); published.signal()
                case .session(.videoFrame): frames += 1; frame.signal()
                case .session(.failed): events.append("failed")
                default: break
                }
            }
        }
    }

    static func connect(_ port: UInt16) -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: DispatchQueue(label: "rtmp-local-receiver-test"))
        return connection
    }

    @Test func strangersNeverDisplaceThePublisher() throws {
        let box = Box()
        let port = UInt16.random(in: 50000...60000)
        let receiver = RTMPLocalReceiver(port: port, token: StreamReceiverToken(value: RTMPReceiveFixtures.key)) {
            box.add($0)
        }
        receiver.start()
        defer { receiver.stop() }
        #expect(box.listening.wait(timeout: .now() + 5) == .success)

        let camera = try RTMPReceiveFixtures.bytes("h264-aac")
        let half = camera.count / 2
        let publisher = Self.connect(port)
        publisher.send(content: Data(camera[..<half]), completion: .idempotent)
        #expect(box.published.wait(timeout: .now() + 5) == .success)
        let framesBefore = box.lock.withLock { box.frames }

        // A silent socket and a publisher with the wrong key arrive while the camera publishes.
        let silent = Self.connect(port)
        let stranger = Self.connect(port)
        let wrongKey = RTMPReceiveFixtures.key.replacingOccurrences(of: "0123", with: "9999")
        let strangerBytes = Self.replacing(camera, RTMPReceiveFixtures.key, with: wrongKey)
        stranger.send(content: Data(strangerBytes), completion: .idempotent)
        // The stranger is closed for its wrong key.
        let refused = DispatchSemaphore(value: 0)
        @Sendable func read() {
            stranger.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { _, _, complete, error in
                if complete || error != nil { refused.signal() } else { read() }
            }
        }
        read()
        #expect(refused.wait(timeout: .now() + 10) == .success)

        // The camera's second half still arrives as frames.
        while box.frame.wait(timeout: .now()) == .success {}
        publisher.send(content: Data(camera[half...]), completion: .idempotent)
        #expect(box.frame.wait(timeout: .now() + 10) == .success)
        box.lock.lock()
        let events = box.events
        let framesAfter = box.frames
        box.lock.unlock()
        #expect(events.filter { $0 == "connected" }.count == 1)
        #expect(!events.contains("disconnected"))
        #expect(framesAfter > framesBefore)

        publisher.cancel()
        #expect(box.gone.wait(timeout: .now() + 5) == .success)
        silent.cancel()
        stranger.cancel()
    }

    /// The fixture with its stream key swapped for another of the same length.
    static func replacing(_ bytes: [UInt8], _ key: String, with other: String) -> [UInt8] {
        let needle = Array(key.utf8)
        let replacement = Array(other.utf8)
        var out = bytes
        var index = 0
        while index + needle.count <= out.count {
            if Array(out[index..<index + needle.count]) == needle {
                out.replaceSubrange(index..<index + needle.count, with: replacement)
                index += needle.count
            } else {
                index += 1
            }
        }
        return out
    }
}
#endif
