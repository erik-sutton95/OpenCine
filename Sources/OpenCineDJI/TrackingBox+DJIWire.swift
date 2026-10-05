import Foundation
import OpenCineCore

// DJI wire members of the camera vocabulary (OpenCineCameraVocabulary) for this file.

extension TrackingBox {
    public static func parseNormalized(
        _ bytes: [UInt8], minimum: Double = minimumNormalizedSize,
        requireOriginFits: Bool = true
    ) -> TrackingBox? {
        guard bytes.count >= 16 else { return nil }
        func f32(_ offset: Int) -> Double? {
            let slice = Array(bytes[offset..<(offset + 4)])
            let bits =
                UInt32(slice[0])
                | (UInt32(slice[1]) << 8)
                | (UInt32(slice[2]) << 16)
                | (UInt32(slice[3]) << 24)
            let value = Double(Float(bitPattern: bits))
            guard value.isFinite, value >= 0, value <= 1 else { return nil }
            return value
        }
        guard let x = f32(0), let y = f32(4), let width = f32(8), let height = f32(12),
            width >= minimum, height >= minimum
        else { return nil }
        if requireOriginFits, x + width > 1.02 || y + height > 1.02 { return nil }
        return TrackingBox(x: x, y: y, width: width, height: height)
    }

    /// `0x02/0x89` notify. 23 B: 5×`00` + 2-byte tag (`a0 41` typical) + 4×f32 LE @7.
    /// Mimo 2026-08-18 take: ~15 Hz while locked; stops after `0xA6` clear.
    public static func parseLivePush(_ payload: [UInt8]) -> TrackingBox? {
        guard payload.count >= 23,
            payload[0] == 0, payload[1] == 0, payload[2] == 0,
            payload[3] == 0, payload[4] == 0
        else { return nil }
        guard
            let raw = parseNormalized(
                Array(payload[7...]), minimum: 0.02, requireOriginFits: false)
        else { return nil }
        return fromCenter(x: raw.x, y: raw.y, width: raw.width, height: raw.height)
    }
}

/// `0x02/0xA5` GET reply. Locked `00 01 00 00`, idle `00 00 00 00`.
/// Extra 4×f32 after the header is an unproven live subject rect — use when it looks legal.
public enum TrackingPoll: Equatable, Sendable {
    case locked(box: TrackingBox?)
    case idle

    public static func parse(_ payload: [UInt8]) -> TrackingPoll? {
        guard payload.count >= 4,
            payload[0] == 0x00, payload[2] == 0x00, payload[3] == 0x00
        else { return nil }
        switch payload[1] {
        case 0x01:
            let extra = payload.count >= 20 ? Array(payload[4...]) : []
            guard let raw = TrackingBox.parseNormalized(extra, requireOriginFits: false) else {
                return .locked(box: nil)
            }
            return .locked(
                box: TrackingBox.fromCenter(
                    x: raw.x, y: raw.y, width: raw.width, height: raw.height))
        case 0x00: return .idle
        default: return nil
        }
    }
}
