import Foundation

/// One unit of encoded media handed to the publish session by a platform encoder.
///
/// Times are milliseconds on the stream's own timeline, which starts near zero when the stream
/// starts. Video is H.264 in Annex-B form (start codes), audio is raw AAC-LC frames.
public enum StreamMediaPacket: Equatable, Sendable {
    /// The H.264 sequence and picture parameter sets, without start codes. Sent before the first
    /// keyframe and again whenever they change.
    case videoConfig(sps: [UInt8], pps: [UInt8])
    /// One H.264 access unit in Annex-B form.
    case video(annexB: [UInt8], isKeyframe: Bool, decodeMs: UInt32, presentMs: UInt32)
    /// The AAC AudioSpecificConfig, sent before the first audio frame.
    case audioConfig(audioSpecificConfig: [UInt8])
    /// One raw AAC frame, without an ADTS header.
    case audio(raw: [UInt8], presentMs: UInt32)
}

/// FLV tag bodies for RTMP video (type 9) and audio (type 8) messages.
enum FLVPayload {
    private static let keyframeAVC: UInt8 = 0x17
    private static let interframeAVC: UInt8 = 0x27
    /// AAC, 44 kHz flag, 16 bit, stereo: the fixed header FLV uses for AAC at any real rate.
    private static let aacHeader: UInt8 = 0xAF

    /// An AVC sequence header carrying one SPS and one PPS. `nil` when the SPS is too short to name
    /// a profile and level or the PPS is empty.
    static func videoConfig(sps: [UInt8], pps: [UInt8]) -> [UInt8]? {
        guard sps.count >= 4, !pps.isEmpty, sps.count <= Int(UInt16.max), pps.count <= Int(UInt16.max) else {
            return nil
        }
        var out: [UInt8] = [keyframeAVC, 0x00, 0, 0, 0]
        out += [0x01, sps[1], sps[2], sps[3], 0xFF, 0xE1]
        out.appendBigEndian(UInt16(sps.count))
        out += sps
        out.append(0x01)
        out.appendBigEndian(UInt16(pps.count))
        out += pps
        return out
    }

    /// An AVC NAL unit tag: the Annex-B units, each with a four-byte length prefix instead of a
    /// start code. `nil` when the input holds no NAL unit.
    static func video(annexB: [UInt8], isKeyframe: Bool, compositionMs: Int32) -> [UInt8]? {
        let units = nalUnits(annexB)
        guard !units.isEmpty else { return nil }
        var out: [UInt8] = [isKeyframe ? keyframeAVC : interframeAVC, 0x01]
        out.appendBigEndian24(UInt32(bitPattern: compositionMs) & 0xFF_FFFF)
        for unit in units {
            out.appendBigEndian(UInt32(unit.count))
            out += unit
        }
        return out
    }

    static func audioConfig(_ audioSpecificConfig: [UInt8]) -> [UInt8] {
        [aacHeader, 0x00] + audioSpecificConfig
    }

    static func audio(_ raw: [UInt8]) -> [UInt8] {
        [aacHeader, 0x01] + raw
    }

    /// The NAL units between Annex-B start codes, without the zero bytes that precede a start code.
    private static func nalUnits(_ bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        var starts: [(code: Int, payload: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, index + 3))
                index += 3
            } else {
                index += 1
            }
        }
        var units: [ArraySlice<UInt8>] = []
        for (position, start) in starts.enumerated() {
            var end = position + 1 < starts.count ? starts[position + 1].code : bytes.count
            while end > start.payload, bytes[end - 1] == 0 { end -= 1 }
            if end > start.payload { units.append(bytes[start.payload..<end]) }
        }
        return units
    }
}
