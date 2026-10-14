/// Live storage has two units. Unknown readings remain absent rather than becoming zero.
public enum MonitorStorageReadoutFormat {
    public static func capacity(gigabytes: Int64?) -> String {
        guard let gigabytes, gigabytes >= 0 else { return "\u{2014}" }
        return "\(gigabytes) GB"
    }
    public static func remainingMinutes(_ minutes: Int?) -> String {
        guard let minutes, minutes >= 0 else { return "\u{2014} Min" }
        return "\(minutes) Min"
    }
}
