/// Rational host-clock cadence that never catches up by producing a burst.
public struct FrameCadence {
    public private(set) var skipped: UInt64 = 0
    private var rate: UInt64
    private var epoch: UInt64?
    private var nextFrame: UInt64 = 0

    public init(framesPerSecond: UInt64) {
        precondition(framesPerSecond == 30 || framesPerSecond == 60)
        rate = framesPerSecond
    }

    /// Starts a fresh timing epoch after a format change without resetting diagnostics.
    public mutating func reset(framesPerSecond: UInt64) {
        precondition(framesPerSecond == 30 || framesPerSecond == 60)
        rate = framesPerSecond
        epoch = nil
        nextFrame = 0
    }

    /// Allows at most one output per call and counts missed periods after a late wake.
    public mutating func isDue(now: UInt64) -> Bool {
        if epoch == nil { epoch = now }
        guard let epoch, now >= epoch else { return false }
        let elapsed = now - epoch
        let frame =
            (elapsed / 1_000_000_000) * rate + (elapsed % 1_000_000_000) * rate / 1_000_000_000
        guard frame >= nextFrame else { return false }
        skipped &+= frame - nextFrame
        nextFrame = frame + 1
        return true
    }
}
