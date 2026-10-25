import OpenCineMedia

/// Live storage has two units. Unknown readings remain absent rather than becoming zero.
public enum MonitorStorageReadoutFormat {
    public static func capacity(gigabytes: Int64?) -> String {
        guard let gigabytes, gigabytes >= 0 else { return "\u{2014}" }
        return "\(gigabytes) GB"
    }
    /// The live storage readout's free space: the nearest whole decimal unit with a compact
    /// uppercase unit (`904.75 GB` reads `905GB`), the one precision in every orientation, app
    /// and platform. Exact bytes stay in `StorageReadout.label` (dashboards, Multiview).
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
    /// The forms one tap on the live storage readout steps to after the free space (A5-11): the
    /// free percentage when the volume reports a capacity, then, in video, the remaining recording
    /// time when the body reports one. Photo never shows a recording time.
    public static func alternatives(percent: String?, recordingTime: String?, photo: Bool) -> [String] {
        [percent, photo ? nil : recordingTime].compactMap { $0 }
    }

    /// The live storage readout's forms, one rule on every app and platform (A5-11): the free
    /// space (`wholeUnitCapacity`), then the free percentage when the volume reports a capacity,
    /// then, in video, the remaining recording time when the camera reports or the integration
    /// estimates one. A tap steps through them (`nextForm`) and back to the free space. Photo
    /// steps free space and percentage only. Kotlin twin: `MonitorStorageReadoutFormat.forms`.
    /// Callers pass a storage observation's `storageReadout` and `recordingTimeLabel`.
    public static func forms(_ readout: StorageReadout?, recordingTime: String?, photo: Bool) -> [String] {
        forms(freeBytes: readout?.freeBytes, percent: readout?.percent, recordingTime: recordingTime, photo: photo)
    }

    /// The same forms from already-read values (a relayed host's media status).
    public static func forms(
        freeBytes: UInt64?, percent: String?, recordingTime: String?, photo: Bool
    ) -> [String] {
        [wholeUnitCapacity(bytes: freeBytes)]
            + alternatives(percent: percent, recordingTime: recordingTime, photo: photo)
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
