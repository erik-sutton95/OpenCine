import Foundation
import Testing

@testable import OpenCineStreaming

/// Recorded bytes from FFmpeg's RTMP sender (`scripts/streaming-rtmp-capture.py`), after the
/// handshake. The Android tests read the same fixture.
enum Golden {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/rtmp-ffmpeg-publish.hex")

    static func bytes() throws -> [UInt8] {
        let text = try String(contentsOf: fixture, encoding: .utf8).filter { !$0.isWhitespace }
        var out: [UInt8] = []
        out.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { throw CocoaError(.fileReadCorruptFile) }
            out.append(byte)
            index = next
        }
        return out
    }

    static func messages() throws -> [RTMPMessage] {
        var reader = RTMPChunkReader()
        return try reader.push(bytes())
    }

    static func commandNames(_ messages: [RTMPMessage]) -> [String] {
        messages.filter { $0.typeID == 20 }.compactMap {
            if case .string(let name)? = try? AMF0.decode($0.payload).first { name } else { nil }
        }
    }
}

@Suite struct RTMPGoldenTests {
    @Test func readerDecodesARealSender() throws {
        let messages = try Golden.messages()
        #expect(Golden.commandNames(messages).starts(with: ["connect", "releaseStream", "FCPublish", "createStream"]))
        #expect(Golden.commandNames(messages).contains("publish"))
        #expect(messages.contains { $0.typeID == 9 && $0.payload.starts(with: [0x17, 0x00]) })
        #expect(messages.contains { $0.typeID == 8 && $0.payload.starts(with: [0xAF, 0x00]) })
    }

    @Test func amfReencodesARealSenderExactly() throws {
        for m in try Golden.messages() where m.typeID == 20 || m.typeID == 18 {
            #expect(AMF0.encode(try AMF0.decode(m.payload)) == m.payload)
        }
    }

    @Test func avcConfigMatchesTheRealSender() throws {
        // FFmpeg's sequence header names the same SPS and PPS our packager is given.
        let messages = try Golden.messages()
        let config = try #require(messages.first { $0.typeID == 9 && $0.payload.starts(with: [0x17, 0x00]) }).payload
        let record = Array(config[5...])
        let spsLength = Int(record[6]) << 8 | Int(record[7])
        let sps = Array(record[8..<8 + spsLength])
        let ppsStart = 8 + spsLength + 1
        let ppsLength = Int(record[ppsStart]) << 8 | Int(record[ppsStart + 1])
        let pps = Array(record[(ppsStart + 2)..<(ppsStart + 2 + ppsLength)])
        let ours = try #require(FLVPayload.videoConfig(sps: sps, pps: pps))
        #expect(Array(ours.prefix(5 + 8 + spsLength + 3 + ppsLength)) == Array(config.prefix(5 + 8 + spsLength + 3 + ppsLength)))
    }

    @Test func videoFramesMatchTheRealSender() throws {
        // Each recorded frame, turned back into Annex-B, packages to the same tag.
        for m in try Golden.messages() where m.typeID == 9 && m.payload.count > 5 && m.payload[1] == 0x01 {
            var annexB: [UInt8] = []
            var at = 5
            while at + 4 <= m.payload.count {
                let length = m.payload[at..<at + 4].reduce(0) { $0 << 8 | Int($1) }
                annexB += [0, 0, 0, 1] + m.payload[(at + 4)..<(at + 4 + length)]
                at += 4 + length
            }
            let composition = Int32(m.payload[2]) << 16 | Int32(m.payload[3]) << 8 | Int32(m.payload[4])
            let ours = FLVPayload.video(annexB: annexB, isKeyframe: m.payload[0] == 0x17, compositionMs: composition)
            #expect(ours == m.payload)
        }
    }
}
