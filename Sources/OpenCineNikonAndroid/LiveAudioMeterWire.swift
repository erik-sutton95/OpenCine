import OpenCineNikon

/// Platform-neutral live-audio payload for the Android JNI seam.
///
/// The shared core decodes Nikon's four sound-indicator bytes and maps them
/// onto the meter's dBFS scale. This wire deliberately carries only that resolved
/// presentation data so Kotlin never learns camera-header layout or meter
/// conversion policy.
struct LiveAudioMeterWire: Equatable, Sendable {
    /// Meter floor: silence, and the value every field carries when the camera reports no
    /// levels. The Kotlin `LiveFrameListener` defaults use the same -60 dBFS.
    static let floorDB = -60.0

    let hasLevels: Bool
    let leftLevelDB: Double
    let leftPeakDB: Double
    let rightLevelDB: Double
    let rightPeakDB: Double

    init(sound: PTPLiveViewSoundIndicator?) {
        guard let sound else {
            hasLevels = false
            leftLevelDB = Self.floorDB
            leftPeakDB = Self.floorDB
            rightLevelDB = Self.floorDB
            rightPeakDB = Self.floorDB
            return
        }

        func decibels(_ segment: Int) -> Double {
            PTPLiveViewSoundIndicator.decibels(segment: segment, floorDB: Self.floorDB)
        }
        hasLevels = true
        leftLevelDB = decibels(sound.currentLeft)
        leftPeakDB = decibels(sound.peakLeft)
        rightLevelDB = decibels(sound.currentRight)
        rightPeakDB = decibels(sound.peakRight)
    }
}
