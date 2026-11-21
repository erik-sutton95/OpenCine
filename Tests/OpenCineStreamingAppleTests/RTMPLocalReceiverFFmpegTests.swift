#if canImport(Network) && canImport(VideoToolbox) && os(macOS)
import CoreVideo
import Foundation
import Network
import OpenCineStreaming
import OpenCineStreamingApple
import Testing

/// Opt-in harness, off in CI: real ffmpeg (`/opt/homebrew/bin/ffmpeg`) publishes to this machine.
/// `OPENCINE_RTMP_FFMPEG=1 swift test --filter RTMPLocalReceiverFFmpeg` runs 1080p30 through the
/// listener and VideoToolbox. `OPENCINE_WRITE_FIXTURES=1` instead records the small publishes in
/// `Fixtures/rtmp-receive/` that the CI tests replay.
@Suite(.serialized) struct RTMPLocalReceiverFFmpegTests {
    static let environment = ProcessInfo.processInfo.environment
    static let codecs: [(String, [String])] = [
        ("h264-aac", ["-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-g", "15"]),
        ("h264-bframes-aac", ["-c:v", "libx264", "-preset", "veryfast", "-bf", "2", "-g", "15"]),
        ("hevc-aac", ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "keyint=15:log-level=error"]),
    ]

    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var pictures = 0
        var size: [Int] = []
        var outOfOrder = 0
        var last: Int64 = .min
        var audio = 0
        var published = false
        var recorded: [UInt8] = []
        var session = RTMPReceiveSession(expectedStreamKey: "0123456789abcdef0123456789abcdef")
    }

    static func ffmpeg(size: String, seconds: String, codec: [String], url: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-re",
            "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=30",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", seconds,
        ] + codec + ["-pix_fmt", "yuv420p", "-c:a", "aac", "-ar", "48000", "-ac", "2", "-f", "flv", url]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test(.enabled(if: environment["OPENCINE_RTMP_FFMPEG"] == "1"), arguments: codecs.map(\.0))
    func ffmpegPublishes1080pThroughTheListener(name: String) throws {
        let token = StreamReceiverToken.random()
        let port = UInt16.random(in: 20000...40000)
        let box = Box()
        let decoder = RTMPVideoDecoder(
            onPicture: { picture in
                box.lock.lock()
                box.pictures += 1
                if picture.presentationMs < box.last { box.outOfOrder += 1 }
                box.last = picture.presentationMs
                box.size = [CVPixelBufferGetWidth(picture.pixelBuffer), CVPixelBufferGetHeight(picture.pixelBuffer)]
                box.lock.unlock()
            }, onError: { print("decoder: \($0)") })
        let receiver = RTMPLocalReceiver(port: port, token: token) { event in
            switch event {
            case .session(.videoConfig(let codec, let record, _)): decoder.configure(codec: codec, record: record)
            case .session(.videoFrame(let frame)): decoder.decode(frame)
            case .session(.audioFrame): box.lock.lock(); box.audio += 1; box.lock.unlock()
            case .session(.publish): box.lock.lock(); box.published = true; box.lock.unlock()
            default: break
            }
        }
        receiver.start()
        defer { receiver.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        let codec = try #require(Self.codecs.first { $0.0 == name }).1
        let status = try Self.ffmpeg(
            size: "1920x1080", seconds: "3", codec: codec, url: token.publishURL(host: "127.0.0.1", port: port))
        Thread.sleep(forTimeInterval: 0.5)
        receiver.queue.sync { decoder.flush() }
        box.lock.lock()
        defer { box.lock.unlock() }
        #expect(status == 0)
        #expect(box.published)
        #expect(box.size == [1920, 1080])
        #expect(box.pictures >= 85)
        #expect(box.outOfOrder == 0)
        #expect(box.audio > 100)
    }

    /// Records the publisher's bytes of a small publish under the fixtures' key.
    @Test(.enabled(if: environment["OPENCINE_WRITE_FIXTURES"] == "1"), arguments: codecs.map(\.0))
    func recordFixture(name: String) throws {
        let port = UInt16.random(in: 20000...40000)
        let box = Box()
        let queue = DispatchQueue(label: "fixture-recorder")
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { connection in
            func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                    if let data, !data.isEmpty {
                        box.lock.lock()
                        box.recorded += data
                        box.lock.unlock()
                        let output = box.session.receive([UInt8](data))
                        if !output.outbound.isEmpty {
                            connection.send(content: Data(output.outbound), completion: .contentProcessed { _ in })
                        }
                    }
                    if complete || error != nil { connection.cancel() } else { read() }
                }
            }
            connection.start(queue: queue)
            read()
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        Thread.sleep(forTimeInterval: 0.3)
        let codec = try #require(Self.codecs.first { $0.0 == name }).1
        let status = try Self.ffmpeg(
            size: "320x180", seconds: "1.2", codec: codec,
            url: "rtmp://127.0.0.1:\(port)/live/0123456789abcdef0123456789abcdef")
        Thread.sleep(forTimeInterval: 0.3)
        #expect(status == 0)
        let bytes = queue.sync { box.lock.withLock { box.recorded } }
        #expect(bytes.count > 10_000)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/rtmp-receive/\(name).bin")
        try Data(bytes).write(to: url)
    }
}
#endif
