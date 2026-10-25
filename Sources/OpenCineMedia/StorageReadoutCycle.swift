import OpenCineCore

/// The live storage readout's tap cycle, one rule on every app, platform and orientation
/// (A5-11; hardware pass 3.4, 7.5 and 8.4): the free space as the nearest whole decimal unit
/// (`904.75 GB` reads `905GB`), then the free percentage when the volume reports a capacity,
/// then, in video, the remaining recording time when the camera reports or the integration
/// estimates one (estimates marked `~`). A tap steps through the forms and back to the free
/// space. Photo steps free space and percentage only. Exact bytes stay in `StorageReadout.label`
/// (dashboards, Multiview). Kotlin twin: `StorageReadoutCycle`.
public enum StorageReadoutCycle {
    /// The cycle for a storage observation; unknown storage reads the unavailable mark alone.
    public static func forms(_ storage: StorageStatus?, photo: Bool) -> [String] {
        let readout = storage?.storageReadout
        return forms(
            freeBytes: readout?.freeBytes, percent: readout?.percent,
            recordingTime: storage?.recordingTimeLabel, photo: photo)
    }

    /// The cycle from already-read values (a relayed host's media status).
    public static func forms(
        freeBytes: UInt64?, percent: String?, recordingTime: String?, photo: Bool
    ) -> [String] {
        [freeSpace(bytes: freeBytes)]
            + alternatives(percent: percent, recordingTime: recordingTime, photo: photo)
    }

    /// The forms after the free space: the percentage, then (video only) the recording time.
    public static func alternatives(percent: String?, recordingTime: String?, photo: Bool) -> [String] {
        [percent, photo ? nil : recordingTime].compactMap { $0 }
    }

    /// The free space as the nearest whole decimal unit with a compact uppercase unit.
    public static func freeSpace(bytes: UInt64?) -> String {
        guard let bytes else { return StorageReadout.unavailable }
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
}
