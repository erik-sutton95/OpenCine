import Foundation

/// Decimal byte labels shared by file metadata and camera storage. Integer half-up rounding
/// keeps the Swift and Kotlin boundary behavior equal; a reported empty store is `0 B`.
public enum ByteCountLabel {
    public static func label(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "0 B" }
        guard bytes >= 1000 else { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        let places = [0, 1, 2, 2]
        var unit = 0
        var divisor: UInt64 = 1000
        while true {
            let scale = places[unit] == 0 ? UInt64(1) : places[unit] == 1 ? 10 : 100
            // Integer half-up rounding: no Double, so both platforms agree on every boundary.
            let scaled = bytes / divisor * scale + (bytes % divisor * scale + divisor / 2) / divisor
            if scaled >= 1000 * scale, unit < units.count - 1 {
                unit += 1
                divisor *= 1000
                continue
            }
            var text = "\(scaled / scale)"
            if scaled % scale > 0 {
                let digits = String(scaled % scale)
                let padded = String(repeating: "0", count: places[unit] - digits.count) + digits
                text += "." + padded.replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            }
            return text + " " + units[unit]
        }
    }
}
