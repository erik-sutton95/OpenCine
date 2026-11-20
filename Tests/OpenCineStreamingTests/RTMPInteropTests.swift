#if os(macOS) && canImport(Network)
import Foundation
import Network
import Testing

@testable import OpenCineStreaming

/// The FFmpeg interop tier: off by default. Run it with
/// `OPENCINE_FFMPEG_INTEROP=1 swift test --filter RTMPInteropTests` on a Mac with `ffmpeg` and
/// `ffprobe` on the path. FFmpeg encodes the media and receives the stream; the engine under test
/// is the publish session, driven over a plain local TCP connection through the internal test seam.
@Suite struct RTMPInteropTests {
    @Test(.enabled(if: Interop.available), .timeLimit(.minutes(1)))
    func ffmpegReceivesAPlayableStream() async throws {
        let probe = try await Interop.publishThenProbe(seconds: 3, cuts: 0)
        #expect(probe.videoCodec == "h264")
        #expect(probe.audioCodec == "aac")
        #expect(probe.width == 1280 && probe.height == 720)
        #expect(probe.packetTimesNeverGoBackward)
        #expect(probe.videoDurationSeconds > 2.5)
    }

    @Test(.enabled(if: Interop.available), .timeLimit(.minutes(1)))
    func reconfiguredVideoStaysPlayable() async throws {
        // A keyframe forced mid-stream with the parameter sets sent again, as a cut does.
        let probe = try await Interop.publishThenProbe(seconds: 3, cuts: 1)
        #expect(probe.videoCodec == "h264")
        #expect(probe.packetTimesNeverGoBackward)
        #expect(probe.videoDurationSeconds > 2.5)
    }
}

enum Interop {
    struct Probe {
        var videoCodec: String?
        var audioCodec: String?
        var width: Int?
        var height: Int?
        var packetTimesNeverGoBackward: Bool
        var videoDurationSeconds: Double
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static var available: Bool {
        ProcessInfo.processInfo.environment["OPENCINE_FFMPEG_INTEROP"] == "1"
            && tool("ffmpeg") != nil && tool("ffprobe") != nil
    }

    static func tool(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        return paths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func publishThenProbe(seconds: Int, cuts: Int) async throws -> Probe {
        let directory = FileManager.default.temporaryDirectory.appending(path: "opencine-rtmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let video = try encodeVideo(seconds: seconds, cuts: cuts, in: directory)
        let audio = try encodeAudio(seconds: seconds, in: directory)
        let port = UInt16.random(in: 20_000...40_000)
        let output = directory.appending(path: "out.flv")
        let receiver = try run(
            "ffmpeg",
            ["-hide_banner", "-loglevel", "error", "-listen", "1", "-f", "flv",
             "-i", "rtmp://127.0.0.1:\(port)/live/interopkey", "-c", "copy", "-y", output.path],
            wait: false)
        defer { if receiver.isRunning { receiver.terminate() } }

        let link = try await TCPLink.connect(port: port)
        let destination = try StreamDestination(
            serverURL: "rtmp://127.0.0.1:\(port)/live", streamKey: "interopkey", allowsPlainRTMP: true)
        var session = RTMPPublishSession(destination: destination)
        try await link.send(session.start())
        while session.state != .live {
            let bytes = try await link.receive()
            guard !bytes.isEmpty else { throw Failure(description: "receiver closed before live") }
            let result = session.receive(bytes)
            if case .failed(let failure)? = result.events.first { throw Failure(description: "session failed: \(failure)") }
            try await link.send(result.outbound)
        }
        for packet in interleave(video: video, audio: audio) {
            try await link.send(session.send(packet))
        }
        try await link.send(session.close())
        link.close()
        try await waitForExit(receiver)
        return try probe(output)
    }

    // MARK: Media

    private static func encodeVideo(seconds: Int, cuts: Int, in directory: URL) throws -> [StreamMediaPacket] {
        let file = directory.appending(path: "video.h264")
        var arguments = [
            "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=\(seconds)",
            "-c:v", "libx264", "-preset", "ultrafast", "-g", "60", "-bf", "0",
            "-bsf:v", "h264_metadata=aud=insert",
        ]
        if cuts > 0 {
            let times = (1...cuts).map { String(format: "%.2f", Double(seconds) * Double($0) / Double(cuts + 1)) }
            arguments += ["-force_key_frames", times.joined(separator: ",")]
        }
        try run("ffmpeg", arguments + ["-f", "h264", "-y", file.path])
        let units = nalUnits(Array(try Data(contentsOf: file)))
        var packets: [StreamMediaPacket] = []
        var access: [[UInt8]] = []
        var frame: UInt32 = 0
        var sps: [UInt8]?
        var pps: [UInt8]?
        var configsSent = 0
        func flush() {
            guard access.contains(where: { [1, 5].contains($0[0] & 0x1F) }) else {
                access = []
                return
            }
            let isKeyframe = access.contains { $0[0] & 0x1F == 5 }
            if isKeyframe, let sps, let pps, configsSent <= cuts {
                packets.append(.videoConfig(sps: sps, pps: pps))
                configsSent += 1
            }
            let ms = frame * 1000 / 30
            packets.append(.video(annexB: access.flatMap { [0, 0, 0, 1] + $0 }, isKeyframe: isKeyframe, decodeMs: ms, presentMs: ms))
            frame += 1
            access = []
        }
        for unit in units {
            switch unit[0] & 0x1F {
            case 9: flush()
            case 7: sps = unit
            case 8: pps = unit
            default: access.append(unit)
            }
        }
        flush()
        return packets
    }

    private static func encodeAudio(seconds: Int, in directory: URL) throws -> [StreamMediaPacket] {
        let file = directory.appending(path: "audio.aac")
        try run(
            "ffmpeg",
            ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=d=\(seconds):sample_rate=48000",
             "-ac", "2", "-c:a", "aac", "-b:a", "160k", "-f", "adts", "-y", file.path])
        let bytes = Array(try Data(contentsOf: file))
        var packets: [StreamMediaPacket] = []
        var at = 0
        var index: UInt32 = 0
        while at + 7 <= bytes.count, bytes[at] == 0xFF, bytes[at + 1] & 0xF0 == 0xF0 {
            let protectionAbsent = bytes[at + 1] & 1 == 1
            let length = Int(bytes[at + 3] & 0x03) << 11 | Int(bytes[at + 4]) << 3 | Int(bytes[at + 5]) >> 5
            let header = protectionAbsent ? 7 : 9
            if packets.isEmpty {
                let objectType = UInt16((bytes[at + 2] >> 6) + 1)
                let rateIndex = UInt16((bytes[at + 2] >> 2) & 0x0F)
                let channels = UInt16((bytes[at + 2] & 1) << 2 | bytes[at + 3] >> 6)
                let config = objectType << 11 | rateIndex << 7 | channels << 3
                packets.append(.audioConfig(audioSpecificConfig: [UInt8(config >> 8), UInt8(config & 0xFF)]))
            }
            packets.append(.audio(raw: Array(bytes[(at + header)..<(at + length)]), presentMs: index * 1024 * 1000 / 48_000))
            index += 1
            at += length
        }
        return packets
    }

    /// Config first, then frames in time order, as a live encoder pair would deliver them.
    private static func interleave(video: [StreamMediaPacket], audio: [StreamMediaPacket]) -> [StreamMediaPacket] {
        var out: [StreamMediaPacket] = []
        var v = video[...]
        var a = audio[...]
        func time(_ packet: StreamMediaPacket?) -> UInt32 {
            switch packet {
            case .video(_, _, let ms, _)?, .audio(_, let ms)?: ms
            case .videoConfig?, .audioConfig?: 0
            case nil: .max
            }
        }
        while !v.isEmpty || !a.isEmpty {
            if case .videoConfig? = v.first, time(v.dropFirst().first) <= time(a.first) {
                out.append(v.removeFirst())
            } else if case .audioConfig? = a.first {
                out.append(a.removeFirst())
            } else if time(v.first) <= time(a.first) {
                out.append(v.removeFirst())
            } else {
                out.append(a.removeFirst())
            }
        }
        return out
    }

    private static func nalUnits(_ bytes: [UInt8]) -> [[UInt8]] {
        var units: [[UInt8]] = []
        var start: Int?
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let start {
                    var end = index
                    while end > start, bytes[end - 1] == 0 { end -= 1 }
                    if end > start { units.append(Array(bytes[start..<end])) }
                }
                start = index + 3
                index += 3
            } else {
                index += 1
            }
        }
        if let start, start < bytes.count { units.append(Array(bytes[start...])) }
        return units
    }

    // MARK: Probe

    private static func probe(_ file: URL) throws -> Probe {
        let pipe = Pipe()
        let process = try run(
            "ffprobe",
            ["-v", "error", "-show_entries", "stream=index,codec_type,codec_name,width,height:packet=stream_index,dts_time,pts_time",
             "-of", "json", file.path],
            stdout: pipe)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let streams = json["streams"] as? [[String: Any]], let packets = json["packets"] as? [[String: Any]]
        else { throw Failure(description: "ffprobe gave no streams") }
        let videoStream = streams.first { $0["codec_type"] as? String == "video" }
        let audioStream = streams.first { $0["codec_type"] as? String == "audio" }
        var lastDTS: [Int: Double] = [:]
        var monotonic = true
        var videoTimes: [Double] = []
        for packet in packets {
            guard let stream = packet["stream_index"] as? Int, let dts = (packet["dts_time"] as? String).flatMap(Double.init)
            else { continue }
            if let last = lastDTS[stream], dts < last { monotonic = false }
            lastDTS[stream] = dts
            if stream == videoStream?["index"] as? Int {
                videoTimes.append((packet["pts_time"] as? String).flatMap(Double.init) ?? dts)
            }
        }
        return Probe(
            videoCodec: videoStream?["codec_name"] as? String, audioCodec: audioStream?["codec_name"] as? String,
            width: videoStream?["width"] as? Int, height: videoStream?["height"] as? Int,
            packetTimesNeverGoBackward: monotonic && !packets.isEmpty,
            videoDurationSeconds: (videoTimes.max() ?? 0) - (videoTimes.min() ?? 0))
    }

    // MARK: Processes

    @discardableResult
    private static func run(_ name: String, _ arguments: [String], wait: Bool = true, stdout: Pipe? = nil) throws -> Process {
        guard let path = tool(name) else { throw Failure(description: "\(name) not found") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        if let stdout { process.standardOutput = stdout }
        try process.run()
        if wait && stdout == nil {
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw Failure(description: "\(name) exited with \(process.terminationStatus)")
            }
        }
        return process
    }

    private static func waitForExit(_ process: Process) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}

/// A plain local TCP connection for the interop tier. Production uses TLS in the platform shells.
final class TCPLink: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "opencine.streaming.interop")
    /// Touched only on `queue`, where the state handler runs.
    private var opened = false

    private init(connection: NWConnection) {
        self.connection = connection
    }

    /// Connects to FFmpeg's one-shot listener, retrying while it is still starting.
    static func connect(port: UInt16) async throws -> TCPLink {
        var lastError: Error?
        for _ in 0..<100 {
            let link = TCPLink(
                connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp))
            do {
                try await link.open()
                return link
            } catch {
                lastError = error
                link.close()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw lastError ?? Interop.Failure(description: "could not connect")
    }

    private func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [self] state in
                guard !opened else { return }
                switch state {
                case .ready:
                    opened = true
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    opened = true
                    continuation.resume(throwing: error)
                case .cancelled:
                    opened = true
                    continuation.resume(throwing: Interop.Failure(description: "cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data.map(Array.init) ?? [])
                }
            }
        }
    }

    func close() {
        connection.cancel()
    }
}
#endif
