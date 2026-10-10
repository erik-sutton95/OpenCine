import Foundation

/// Operator choice already stored by deployed hosts. Shared native and socket owners consume
/// these exact values; no brand selects an encoder or queue discipline.
public enum RelayEncoderProfile: String, CaseIterable, Codable, Equatable, Sendable {
    case lowLatency
    case quality

    public var title: String {
        switch self {
        case .lowLatency: "Low latency"
        case .quality: "Quality"
        }
    }
    public var maxKeyframeInterval: Int {
        switch self {
        case .lowLatency: 50
        case .quality: 120
        }
    }
    public var maxInFlightFramesPerPeer: Int {
        switch self {
        case .lowLatency: 2
        case .quality: 4
        }
    }
}

/// Immutable adaptation facts. The moving window/rung state remains owned by the shared
/// WatcherRelayBitrate, including its consecutive-saturation rule and operator ceiling.
public struct RelayBitratePolicy: Equatable, Sendable {
    public let ladder: [Int]
    public let maxFrameQPLadder: [Int]
    public let stepDownSaturation: Double
    public let stepUpSaturation: Double
    public let windowSeconds: TimeInterval
    public let stepUpAfterCleanSeconds: TimeInterval

    public init(
        ladder: [Int] = [10_000_000, 7_000_000, 4_500_000, 3_000_000],
        maxFrameQPLadder: [Int] = [36, 39, 42, 45], stepDownSaturation: Double = 0.3,
        stepUpSaturation: Double = 0.05, windowSeconds: TimeInterval = 5,
        stepUpAfterCleanSeconds: TimeInterval = 30
    ) {
        precondition(!ladder.isEmpty && ladder.count == maxFrameQPLadder.count)
        precondition(windowSeconds > 0 && stepUpAfterCleanSeconds >= 0)
        self.ladder = ladder
        self.maxFrameQPLadder = maxFrameQPLadder
        self.stepDownSaturation = stepDownSaturation
        self.stepUpSaturation = stepUpSaturation
        self.windowSeconds = windowSeconds
        self.stepUpAfterCleanSeconds = stepUpAfterCleanSeconds
    }
}

/// Measured camera starvation threshold. Hosts supply their exercised baseline fraction/floor;
/// the shared v1 owner keeps 0.8 with no floor, while another deployment supplies 0.72/15.
public struct RelayCameraStarvationPolicy: Equatable, Sendable {
    public let absoluteFloorFPS: Double
    public let baselineFraction: Double

    public init(absoluteFloorFPS: Double, baselineFraction: Double) {
        self.absoluteFloorFPS = absoluteFloorFPS
        self.baselineFraction = baselineFraction
    }

    public func threshold(soloBaselineFPS: Double) -> Double {
        guard soloBaselineFPS > 0 else { return absoluteFloorFPS }
        return max(absoluteFloorFPS, soloBaselineFPS * baselineFraction)
    }
}

/// Compatibility shape for callers that already own an encode stage. Admission and completion
/// delegate to the same bounded policy the shared watcher uses.
public struct RelayEncodeLane: Equatable, Sendable {
    public static let defaultDepth = WatcherRelayEncodePolicy.capacity
    private var policy: WatcherRelayEncodePolicy
    public var depth: Int { policy.depth }
    public var framesInFlight: Int { policy.inFlight }

    public init(depth: Int = RelayEncodeLane.defaultDepth) {
        policy = WatcherRelayEncodePolicy(depth: depth)
    }
    public mutating func admit() -> Bool { policy.admit() }
    public mutating func release() { policy.complete() }
}
