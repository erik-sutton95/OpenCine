#if os(macOS) && canImport(VideoToolbox) && canImport(Network)
import AVFoundation
import Foundation
import Testing

@testable import OpenCineStreaming
@testable import OpenCineStreamingApple

/// The Apple shell end to end against FFmpeg: off by default. Run it with
/// `OPENCINE_FFMPEG_INTEROP=1 swift test --filter StreamAppleInteropTests` on a Mac with `ffmpeg` and
/// `ffprobe` on the path. Synthetic pictures and a tone go through the real fitter, VideoToolbox,
/// the AAC encoder, the run controller and a plain local socket (the internal test seam) to an
/// FFmpeg receiver, in real time. It proves the wire format, not a real service.
@Suite struct StreamAppleInteropTests {
    static var available: Bool {
        ProcessInfo.processInfo.environment["OPENCINE_FFMPEG_INTEROP"] == "1" && tool("ffmpeg") != nil
            && tool("ffprobe") != nil
    }

    static func tool(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        return paths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @Test(.enabled(if: available), .timeLimit(.minutes(1)))
    func ffmpegReceivesThePublishersStream() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "opencine-rtmp-apple-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "out.flv")
        let port = UInt16.random(in: 20_000...40_000)
        let receiver = Process()
        receiver.executableURL = URL(fileURLWithPath: Self.tool("ffmpeg")!)
        receiver.arguments = [
            "-hide_banner", "-loglevel", "error", "-listen", "1", "-f", "flv",
            "-i", "rtmp://127.0.0.1:\(port)/live/interopkey", "-c", "copy", "-y", output.path,
        ]
        receiver.standardInput = FileHandle.nullDevice
        try receiver.run()
        defer { if receiver.isRunning { receiver.terminate() } }
        try await Task.sleep(for: .milliseconds(500))  // FFmpeg's one-shot listener; the tier may wait

        let statuses = AsyncStream.makeStream(of: StreamRun.Status.self)
        let publisher = StreamPublisher(
            destination: try StreamDestination(testOnlyPlainServerURL: "rtmp://127.0.0.1:\(port)/live", streamKey: "interopkey"),
            format: MediaFixtures.format720, fitting: .fit,
            connection: { NetworkStreamConnection(plainHost: $0, port: $1) }, now: { .now() }, drivesTimers: true)
        publisher.onStatus { statuses.continuation.yield($0) }
        publisher.start()
        for await status in statuses.stream {
            if status.phase == .live { break }
            if case .ended = status.phase { Issue.record("ended before live: \(status.phase)"); return }
        }
        // Three seconds of a 4:3 source (fitted with bars) and a tone, in real time.
        for step in 0..<90 {
            let shade = UInt8(step * 2)
            publisher.submitVideo(MediaFixtures.picture(width: 1024, height: 768) { x, _ in (shade, UInt8(x % 256), 128) })
            if step % 3 == 0 { publisher.submitAudio(MediaFixtures.tone(frames: 4_800)) }
            try await Task.sleep(for: .milliseconds(33))
        }
        publisher.stop()
        _ = publisher.status
        try await Task.sleep(for: .milliseconds(300))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                receiver.waitUntilExit()
                continuation.resume()
            }
        }

        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: Self.tool("ffprobe")!)
        probe.arguments = [
            "-v", "error", "-show_entries",
            "stream=index,codec_type,codec_name,profile,width,height,sample_rate,channels:packet=stream_index,dts_time",
            "-of", "json", output.path,
        ]
        let pipe = Pipe()
        probe.standardOutput = pipe
        try probe.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let streams = try #require(json["streams"] as? [[String: Any]])
        let video = try #require(streams.first { $0["codec_type"] as? String == "video" })
        let audio = try #require(streams.first { $0["codec_type"] as? String == "audio" })
        #expect(video["codec_name"] as? String == "h264")
        #expect(video["profile"] as? String == "High")
        #expect(video["width"] as? Int == 1280 && video["height"] as? Int == 720)
        #expect(audio["codec_name"] as? String == "aac")
        #expect(audio["sample_rate"] as? String == "48000")
        #expect(audio["channels"] as? Int == 2)
        var last: [Int: Double] = [:]
        var videoPackets = 0
        for packet in json["packets"] as? [[String: Any]] ?? [] {
            guard let index = packet["stream_index"] as? Int, let dts = (packet["dts_time"] as? String).flatMap(Double.init)
            else { continue }
            #expect(dts >= (last[index] ?? -1))
            last[index] = dts
            if index == video["index"] as? Int { videoPackets += 1 }
        }
        #expect(videoPackets >= 60)
    }
}
#endif
