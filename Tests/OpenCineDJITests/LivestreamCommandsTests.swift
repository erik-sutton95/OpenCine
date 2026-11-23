import Foundation
import OpenCineCore
import Testing

@testable import OpenCineDJI

/// The livestream commands against the hand-built goldens in `Fixtures/dji-livestream-frames.tsv`
/// (shared with the Android wire test).
@Suite struct LivestreamCommandsTests {
    static let goldens: [String: (set: UInt8, id: UInt8, payload: [UInt8])] = {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/dji-livestream-frames.tsv").path
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var rows: [String: (UInt8, UInt8, [UInt8])] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.components(separatedBy: "\t")
            guard f.count == 4, let set = UInt8(f[1], radix: 16), let id = UInt8(f[2], radix: 16) else { continue }
            rows[f[0]] = (set, id, hexBytes(f[3]))
        }
        return rows
    }()

    static func hexBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return bytes
    }

    static func expect(_ frame: Duml.Frame, is name: String) throws {
        let golden = try #require(goldens[name], "missing golden \(name)")
        #expect(frame.sender == 2 && frame.receiver == 8 && frame.flags == 0x40, "\(name)")
        #expect(frame.cmdSet == golden.set && frame.cmdId == golden.id, "\(name)")
        #expect(frame.payload == golden.payload, "\(name)")
    }

    static let url = "rtmp://172.20.10.1:1935/live/abcd"

    @Test func framesMatchTheGoldens() throws {
        try Self.expect(LivestreamCommands.prepare(seq: 1), is: "prepare")
        try Self.expect(LivestreamCommands.start(seq: 2), is: "start")
        try Self.expect(LivestreamCommands.end(seq: 3), is: "end")
        let p4 = LivestreamCommands.preset(frameRate: 30, bitrateKbps: 6000)
        try Self.expect(
            LivestreamCommands.configureJSON(url: Self.url, preset: p4, codec: .hevc, seq: 4),
            is: "configure-v01-hevc-30fps-6000kbps")
        try Self.expect(
            LivestreamCommands.configureJSON(url: Self.url, preset: p4, codec: .h264, seq: 5),
            is: "configure-v01-avc-30fps-6000kbps")
        let p3 = LivestreamCommands.preset(frameRate: 25, bitrateKbps: 6000)
        #expect(p3 == [0x0A, 0x70, 0x17, 0x02, 0x01, 0x02, 0x00, 0x00, 0x00])
        try Self.expect(
            LivestreamCommands.configureDirectURL(url: Self.url, preset: p3, seq: 6),
            is: "configure-v00-pocket3-25fps-6000kbps")
    }

    @Test func anAddressTooLongForTheFrameIsRefused() {
        let long = "rtmp://" + String(repeating: "a", count: 300)
        let preset = LivestreamCommands.preset(frameRate: 30, bitrateKbps: 6000)
        #expect(throws: LivestreamCommands.Failure.urlTooLong) {
            try LivestreamCommands.configureDirectURL(url: long, preset: preset, seq: 1)
        }
        #expect(throws: LivestreamCommands.Failure.urlTooLong) {
            try LivestreamCommands.configureJSON(url: long, preset: preset, codec: .h264, seq: 1)
        }
    }

    @Test func onlyListedBodiesDeclareTheCapability() throws {
        let pro = try #require(DJIStreamPublishing.capability(for: CameraModel(name: "Osmo Pocket 4 Pro")))
        #expect(!pro.experimental && !pro.takesLUT)
        #expect(pro.codecs == [.hevc, .h264] && Set(pro.frameRates) == [25, 30])
        #expect(pro.width == 1920 && pro.height == 1080)
        let four = try #require(DJIStreamPublishing.capability(for: CameraModel(name: "Osmo Pocket 4")))
        #expect(four.experimental && four.codecs == [.hevc, .h264])
        let three = try #require(DJIStreamPublishing.capability(for: CameraModel(name: "Osmo Pocket 3")))
        #expect(three.experimental && three.codecs == [.h264])
        #expect(DJIStreamPublishing.capability(for: CameraModel(name: "Osmo Nano")) == nil)
        #expect(DJIStreamPublishing.capability(for: CameraModel(name: "Osmo Action 6")) == nil)
        #expect(DJIStreamPublishing.capability(for: CameraModel(name: "DJI Osmo camera")) == nil)
    }
}
