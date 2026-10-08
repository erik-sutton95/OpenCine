import Foundation

/// Shared encode ladder. Operator Broadcast priority is `ceilingIndex` (0 = highest quality).
public struct WatcherRelayBitrate: Equatable, Sendable {
    private static let defaultPolicy = RelayBitratePolicy()
    public static let ladder = defaultPolicy.ladder
    public static let stepDownSaturation = defaultPolicy.stepDownSaturation
    public static let stepUpSaturation = defaultPolicy.stepUpSaturation
    public static let windowSeconds = defaultPolicy.windowSeconds
    public static let stepUpAfterCleanSeconds = defaultPolicy.stepUpAfterCleanSeconds

    public let policy: RelayBitratePolicy
    public var ceilingIndex: Int
    public private(set) var rungIndex: Int
    private var windowStartedAt: TimeInterval
    private var ticksInWindow = 0
    private var saturatedTicksInWindow = 0
    private var previousTickSaturated = false
    private var cleanSince: TimeInterval

    public init(
        ceilingIndex: Int = 0, now: TimeInterval = 0,
        policy: RelayBitratePolicy = RelayBitratePolicy()
    ) {
        self.policy = policy
        self.ceilingIndex = Self.clamp(ceilingIndex, count: policy.ladder.count)
        self.rungIndex = self.ceilingIndex
        self.windowStartedAt = now
        self.cleanSince = now
    }

    public var bitsPerSecond: Int {
        let i = max(rungIndex, ceilingIndex)
        return policy.ladder[Self.clamp(i, count: policy.ladder.count)]
    }

    public var maxFrameQP: Int {
        policy.maxFrameQPLadder[
            Self.clamp(max(rungIndex, ceilingIndex), count: policy.ladder.count)]
    }

    public mutating func recordTick(saturated: Bool, cameraStarving: Bool, now: TimeInterval)
        -> Int?
    {
        let full = saturated || cameraStarving
        ticksInWindow += 1
        if full && previousTickSaturated { saturatedTicksInWindow += 1 }
        previousTickSaturated = full
        guard now - windowStartedAt >= policy.windowSeconds, ticksInWindow > 0 else { return nil }

        let saturation = Double(saturatedTicksInWindow) / Double(ticksInWindow)
        ticksInWindow = 0
        saturatedTicksInWindow = 0
        windowStartedAt = now
        ceilingIndex = Self.clamp(ceilingIndex, count: policy.ladder.count)

        if saturation > policy.stepDownSaturation {
            cleanSince = now
            if rungIndex < policy.ladder.count - 1 {
                rungIndex += 1
                return bitsPerSecond
            }
            return nil
        }
        if saturation > policy.stepUpSaturation {
            cleanSince = now
            return nil
        }
        if rungIndex > ceilingIndex, now - cleanSince >= policy.stepUpAfterCleanSeconds {
            rungIndex -= 1
            cleanSince = now
            return bitsPerSecond
        }
        return nil
    }

    private static func clamp(_ index: Int, count: Int) -> Int {
        min(max(0, index), count - 1)
    }
}
