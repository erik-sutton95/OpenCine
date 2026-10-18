/// Live storage has two units. Unknown readings remain absent rather than becoming zero.
public enum MonitorStorageReadoutFormat {
    public static func capacity(gigabytes: Int64?) -> String {
        guard let gigabytes, gigabytes >= 0 else { return "\u{2014}" }
        return "\(gigabytes) GB"
    }
    /// Portrait capacity: the nearest whole decimal unit with a compact uppercase unit
    /// (`904.75 GB` reads `905GB`). The underlying bytes and the landscape label are unchanged.
    public static func wholeUnitCapacity(bytes: UInt64?) -> String {
        guard let bytes else { return "\u{2014}" }
        guard bytes > 0 else { return "0B" }
        guard bytes >= 1000 else { return "\(bytes)B" }
        let units = ["KB", "MB", "GB", "TB"]
        var unit = 0
        var divisor: UInt64 = 1000
        while true {
            let remainder = bytes % divisor
            // Integer half-up rounding; the remainder is below the divisor, so doubling is safe.
            let rounded = bytes / divisor + (remainder * 2 >= divisor ? 1 : 0)
            if rounded >= 1000, unit < units.count - 1 {
                unit += 1
                divisor *= 1000
                continue
            }
            return "\(rounded)\(units[unit])"
        }
    }
    public static func remainingMinutes(_ minutes: Int?) -> String {
        guard let minutes, minutes >= 0 else { return "\u{2014} Min" }
        return "\(minutes) Min"
    }
}
