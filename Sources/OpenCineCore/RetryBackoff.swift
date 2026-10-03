import Foundation

/// Pure jittered exponential delay. Inputs and output use the caller's same time unit;
/// choosing a clock, sleeping, retry limits and random samples belongs to the owner.
public struct RetryBackoff: Sendable, Equatable {
    public var initialDelay: Double
    public var maximumDelay: Double
    public var multiplier: Double
    public var jitterFraction: Double

    public init(
        initialDelay: Double, maximumDelay: Double,
        multiplier: Double = 2, jitterFraction: Double = 0.3
    ) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.multiplier = multiplier
        self.jitterFraction = jitterFraction
    }

    public func delay(forAttempt attempt: Int, jitter: Double) -> Double {
        let exponent = Double(max(0, attempt))
        let capped = min(maximumDelay, initialDelay * pow(multiplier, exponent))
        let clampedJitter = min(1, max(0, jitter))
        let signedSpread = (clampedJitter * 2 - 1) * jitterFraction
        let jittered = capped * (1 + signedSpread)
        return min(maximumDelay, max(0, jittered))
    }
}
