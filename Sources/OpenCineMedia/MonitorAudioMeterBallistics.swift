import Foundation

/// One channel of a broadcast-style dBFS bar meter: the decaying level bar plus its peak-hold
/// marker. Values are dBFS clamped to `MonitorAudioMeterBallistics.floorDB`…0.
public struct MonitorAudioMeterChannel: Equatable, Sendable {
    /// Bar level in dBFS.
    public var levelDB: Double
    /// Peak-hold marker in dBFS (never reads below `levelDB`).
    public var peakDB: Double
    /// Seconds the current peak marker has been held; drives the hold-then-decay release.
    public var peakAge: Double

    public init(
        levelDB: Double = MonitorAudioMeterBallistics.floorDB,
        peakDB: Double = MonitorAudioMeterBallistics.floorDB,
        peakAge: Double = 0
    ) {
        self.levelDB = levelDB
        self.peakDB = peakDB
        self.peakAge = peakAge
    }

    public static let silent = MonitorAudioMeterChannel()
}

/// Stereo readout published to the live audio-levels panel.
public struct MonitorAudioMeterLevels: Equatable, Sendable {
    public var left: MonitorAudioMeterChannel
    public var right: MonitorAudioMeterChannel

    public init(left: MonitorAudioMeterChannel, right: MonitorAudioMeterChannel) {
        self.left = left
        self.right = right
    }

    public static let silent = MonitorAudioMeterLevels(left: .silent, right: .silent)
}

/// dBFS conversion and meter ballistics (instant attack, timed decay, peak hold). Pure; a
/// source snapshot supplies linear frame peaks and a wall-clock `dt`.
public enum MonitorAudioMeterBallistics {
    /// Meter floor; anything quieter renders as silence.
    public static let floorDB = -60.0
    /// Bar fall rate once the signal drops (dB per second); fast but readable, PPM-style.
    public static let levelDecayPerSecond = 26.0
    /// How long a peak marker holds before it starts to fall.
    public static let peakHoldSeconds = 1.8
    /// Peak-marker fall rate once the hold expires (dB per second).
    public static let peakDecayPerSecond = 12.0

    /// Linear amplitude (0…1) → dBFS, clamped to `floorDB`…0.
    public static func decibels(fromLinear amplitude: Double) -> Double {
        guard amplitude > 0 else { return floorDB }
        return max(floorDB, min(0, 20 * log10(amplitude)))
    }

    /// Advances one channel by `dt` seconds, given the loudest linear sample amplitude observed
    /// since the previous step. The bar attacks instantly and decays at `levelDecayPerSecond`; the
    /// peak marker grabs new maxima, holds `peakHoldSeconds`, then falls at `peakDecayPerSecond`.
    public static func step(
        _ channel: MonitorAudioMeterChannel, peakLinear: Double, dt: Double
    ) -> MonitorAudioMeterChannel {
        let dt = max(0, dt)
        let incoming = decibels(fromLinear: peakLinear)
        var next = channel
        let decayed = max(floorDB, channel.levelDB - levelDecayPerSecond * dt)
        next.levelDB = max(incoming, decayed)
        if incoming >= channel.peakDB {
            next.peakDB = incoming
            next.peakAge = 0
        } else {
            next.peakAge = channel.peakAge + dt
            if next.peakAge > peakHoldSeconds {
                next.peakDB = max(floorDB, channel.peakDB - peakDecayPerSecond * dt)
            }
        }
        next.peakDB = max(next.peakDB, next.levelDB)
        return next
    }
}
