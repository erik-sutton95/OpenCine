import Foundation

/// The SIMULATED camera values a `ReviewLaunch` with the LIVE screen stages, so every app's review
/// shows the same live monitor. Each app maps them into its own integration's status and adds only
/// its own colour name (D-Log2, I-Log). The Kotlin twin (`com.opencapture.monitorui.ReviewLiveValues`)
/// has the same fields; both read `Fixtures/review-live-values.tsv`. Debug review only: nothing here
/// reaches a camera.
public struct ReviewLiveValues: Hashable, Sendable {
    public var iso: Int
    public var shutterDenominator: Int
    public var whiteBalanceKelvin: Int
    public var recordWidth: Int
    public var recordHeight: Int
    public var framesPerSecond: Int
    public var batteryPercent: Int
    public var storageFreeMebibytes: Int64
    public var storageTotalMebibytes: Int64
    public var timecodeHours: Int
    public var timecodeMinutes: Int
    public var timecodeSeconds: Int

    public init(
        iso: Int = 1600, shutterDenominator: Int = 50, whiteBalanceKelvin: Int = 5600,
        recordWidth: Int = 3840, recordHeight: Int = 2160, framesPerSecond: Int = 25,
        batteryPercent: Int = 68, storageFreeMebibytes: Int64 = 107 * 1024,
        storageTotalMebibytes: Int64 = 128 * 1024, timecodeHours: Int = 15, timecodeMinutes: Int = 39,
        timecodeSeconds: Int = 50
    ) {
        self.iso = iso
        self.shutterDenominator = shutterDenominator
        self.whiteBalanceKelvin = whiteBalanceKelvin
        self.recordWidth = recordWidth
        self.recordHeight = recordHeight
        self.framesPerSecond = framesPerSecond
        self.batteryPercent = batteryPercent
        self.storageFreeMebibytes = storageFreeMebibytes
        self.storageTotalMebibytes = storageTotalMebibytes
        self.timecodeHours = timecodeHours
        self.timecodeMinutes = timecodeMinutes
        self.timecodeSeconds = timecodeSeconds
    }

    public var storageFreeBytes: Int64 { storageFreeMebibytes * 1_048_576 }
    public var storageTotalBytes: Int64 { storageTotalMebibytes * 1_048_576 }

    /// The one fixture every app's LIVE review stages.
    public static let simulated = ReviewLiveValues()
}
