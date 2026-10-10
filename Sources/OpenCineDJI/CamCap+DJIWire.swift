import Foundation
import OpenCineCore

// DJI wire members of the camera vocabulary (OpenCineCameraVocabulary) for this file.

extension CamCapShutter {
    public static let subscribeKey = "camcap_shutter"

    /// 1/N denoms in camera order. Empty if the blob is not a shutter table.
    public static func parseDenoms(_ value: [UInt8]) -> [Int] {
        guard let items = parseItems(value) else { return [] }
        var seen = Set<Int>()
        var out: [Int] = []
        for item in items {
            guard case .fraction(let denom) = item else { continue }
            guard (1...16_000).contains(denom), !seen.contains(denom) else { continue }
            seen.insert(denom)
            out.append(denom)
        }
        return out
    }

    enum Item: Equatable, Sendable {
        case fraction(Int)
        case seconds(Int)
    }

    static func parseItems(_ value: [UInt8]) -> [Item]? {
        guard value.count >= 13, value[0] == 0x01 else { return nil }
        let inner = Int(value[1]) | (Int(value[2]) << 8)
        guard inner >= 10, 3 + inner <= value.count else { return nil }
        let body = Array(value[3..<(3 + inner)])
        if let items = itemsFromHeader(body) { return items }
        return scanItems(body)
    }

    private static func itemsFromHeader(_ body: [UInt8]) -> [Item]? {
        let count = Int(body[9])
        let payload = Array(body.dropFirst(10))
        guard count > 0, payload.count == count * 3 else { return nil }
        let items = decodeTriplets(payload)
        return items.isEmpty ? nil : items
    }

    /// Firmware that shifts the 10-byte header: take the densest run of 3-byte records.
    private static func scanItems(_ body: [UInt8]) -> [Item]? {
        var best: [Item] = []
        let maxOff = min(16, max(0, body.count - 6))
        for off in 0...maxOff {
            let slice = Array(body[off...])
            let n = slice.count / 3
            guard n >= 2 else { continue }
            let items = decodeTriplets(Array(slice.prefix(n * 3)))
            if fractionCount(items) > fractionCount(best) {
                best = items
            }
        }
        return fractionCount(best) >= 2 ? best : nil
    }

    private static func fractionCount(_ items: [Item]) -> Int {
        items.reduce(0) { count, item in
            if case .fraction = item { return count + 1 }
            return count
        }
    }

    private static func decodeTriplets(_ bytes: [UInt8]) -> [Item] {
        var items: [Item] = []
        var i = 0
        while i + 2 < bytes.count {
            let raw = Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
            if raw & 0x8000 != 0 {
                let denom = raw & 0x7FFF
                if (1...16_000).contains(denom) {
                    items.append(.fraction(denom))
                }
            } else if (1...60).contains(raw) {
                items.append(.seconds(raw))
            }
            i += 3
        }
        return items
    }
}

extension CamCapIso {
    public static let subscribeKey = "camcap_iso"

    public static func parseIndices(_ value: [UInt8]) -> [IsoIndex] {
        guard value.count >= 5, value[0] == 0x01 else { return [] }
        let inner = Int(value[1]) | (Int(value[2]) << 8)
        guard inner >= 2, 3 + inner <= value.count else { return [] }
        let body = Array(value[3..<(3 + inner)])
        let count = Int(body[1])
        guard body[0] == 0, count >= 1, body.count >= 2 + count else { return [] }
        return body[2..<(2 + count)].compactMap { IsoIndex(djiWire: $0) }
    }
}

extension CamCapColorMode {
    public static let subscribeKey = "camcap_color_mode"

    public static func parse(_ value: [UInt8], model: CameraModel? = nil) -> [ColorMode] {
        guard value.count >= 5, value[0] == 0x01 else { return [] }
        let inner = Int(value[1]) | (Int(value[2]) << 8)
        guard inner >= 2, 3 + inner <= value.count else { return [] }
        let body = Array(value[3..<(3 + inner)])
        let count = Int(body[0])
        guard count >= 1, body.count >= 1 + count else { return [] }
        return body[1..<(1 + count)].compactMap { ColorMode.fromWire($0, model: model) }
    }
}

extension CamCapVideoFormat {
    public static let subscribeKey = "camcap_video_format"

    public static func parse(_ value: [UInt8]) -> [VideoFormat] {
        guard value.count >= 5, value[0] == 0x01 else { return [] }
        let inner = Int(value[1]) | (Int(value[2]) << 8)
        guard inner >= 2, 3 + inner <= value.count else { return [] }
        let body = Array(value[3..<(3 + inner)])
        let count = Int(body[0])
        guard count >= 1, body.count >= 1 + count * 3 else { return [] }
        var out: [VideoFormat] = []
        var seen = Set<VideoFormat>()
        var i = 1
        for _ in 0..<count {
            guard i + 2 < body.count else { break }
            if let format = VideoFormat.parseVideoParamV2(Array(body[i..<(i + 2)])),
                seen.insert(format).inserted
            {
                out.append(format)
            }
            i += 3
        }
        return out
    }
}

/// `camcap_iso_auto_max` — Auto ISO ceiling table + color-mode base.
///
/// ```
/// 02 | innerLen:u16-LE | count | count × IsoLimit | base:u16-LE
/// ```
/// Pocket 4 Pro Normal/HDR: `02 0b 00 08 02…09 64 00` → 100 + 200…25600.
/// D-Log: `02 07 00 04 04…07 90 01` → 400 + 800…6400.
/// D-Log2: `01 01 00 00` → no Auto.
///
/// Wheel lists stay on `ColorMode.isoAutoLimits` / `isoAutoBase(for:)`. Pocket 3
/// / Pocket 4 Rec.709 labels use floor 50 even though this 4 Pro capture is 100.
/// This parser pins the capture; it is not subscribed.
public enum CamCapIsoAutoMax {
    public static let subscribeKey = "camcap_iso_auto_max"

    public static func parse(_ value: [UInt8]) -> (base: Int, limits: [IsoLimit])? {
        guard !value.isEmpty else { return nil }
        if value[0] == 0x01 {
            return (0, [])
        }
        guard value.count >= 6, value[0] == 0x02 else { return nil }
        let inner = Int(value[1]) | (Int(value[2]) << 8)
        guard inner >= 3, 3 + inner <= value.count else { return nil }
        let body = Array(value[3..<(3 + inner)])
        let count = Int(body[0])
        guard count >= 1, body.count >= 1 + count + 2 else { return nil }
        let limits = body[1..<(1 + count)].compactMap { IsoLimit(rawValue: $0) }
        guard limits.count == count else { return nil }
        let baseAt = 1 + count
        let base = Int(UInt16(body[baseAt]) | (UInt16(body[baseAt + 1]) << 8))
        return (base, limits)
    }
}
