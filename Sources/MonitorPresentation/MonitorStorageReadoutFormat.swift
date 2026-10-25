import OpenCineMedia

/// Live storage has two units. Unknown readings remain absent rather than becoming zero.
public enum MonitorStorageReadoutFormat {
    public static func capacity(gigabytes: Int64?) -> String {
        guard let gigabytes, gigabytes >= 0 else { return "\u{2014}" }
        return "\(gigabytes) GB"
    }
    /// The live storage readout's free space (`StorageReadoutCycle.freeSpace`).
    public static func wholeUnitCapacity(bytes: UInt64?) -> String {
        StorageReadoutCycle.freeSpace(bytes: bytes)
    }
    /// The forms one tap steps to after the free space (`StorageReadoutCycle.alternatives`).
    public static func alternatives(percent: String?, recordingTime: String?, photo: Bool) -> [String] {
        StorageReadoutCycle.alternatives(percent: percent, recordingTime: recordingTime, photo: photo)
    }

    /// The form a tap selects after `current`, of `count` forms. With nothing to step to the
    /// readout stays on the free space, so a later alternative starts from it.
    public static func nextForm(after current: Int, count: Int) -> Int {
        count > 1 ? (current + 1) % count : 0
    }

    public static func remainingMinutes(_ minutes: Int?) -> String {
        guard let minutes, minutes >= 0 else { return "\u{2014} Min" }
        return "\(minutes) Min"
    }
}
