import Foundation

/// Encoding and transport share these reservations. Retirement invalidates results immediately;
/// SDK work may retain its reservation until it completes, as on WatchConnectivity.
public struct RelayPreviewReservations: Sendable {
    public struct Ticket: Hashable, Sendable {
        public let generation: UInt64
        public let sequence: UInt64
    }
    public let maximumInFlight: Int
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var outstanding: Set<Ticket> = []
    public var inFlightCount: Int { outstanding.count }
    public init(maximumInFlight: Int = 3) {
        precondition(maximumInFlight > 0)
        self.maximumInFlight = maximumInFlight
    }
    public mutating func reserve() -> Ticket? {
        guard outstanding.count < maximumInFlight else { return nil }
        sequence &+= 1
        let ticket = Ticket(generation: generation, sequence: sequence)
        outstanding.insert(ticket)
        return ticket
    }
    public func isCurrent(_ ticket: Ticket) -> Bool {
        ticket.generation == generation && outstanding.contains(ticket)
    }
    @discardableResult public mutating func complete(_ ticket: Ticket) -> Bool {
        outstanding.remove(ticket) != nil
    }
    public mutating func invalidate(releasingOutstanding: Bool = false) {
        generation &+= 1
        if releasingOutstanding { outstanding.removeAll() }
    }
}

public struct RelayPreviewProfile: Equatable, Sendable {
    public let maximumWidth: Int
    public let qualityPercent: Int
    public init(maximumWidth: Int, qualityPercent: Int) {
        precondition(maximumWidth > 0 && (0...100).contains(qualityPercent))
        self.maximumWidth = maximumWidth
        self.qualityPercent = qualityPercent
    }
}

/// Supplied deployment budgets, ordered from highest quality to lowest. An initial RTT hint
/// preserves an exercised scheduling recipe but is never exposed as an observed measurement.
public struct RelayPreviewPacingPolicy: Sendable {
    public let profiles: [RelayPreviewProfile]
    public let roundTripThresholds: [TimeInterval]
    public let initialIndex: Int
    public let initialRoundTripHint: TimeInterval?
    public let previousSampleWeight: Double
    public let currentSampleWeight: Double
    public let maximumSampleSeconds: TimeInterval?
    public let sampleUnitsPerSecond: Double
    public init(
        profiles: [RelayPreviewProfile], roundTripThresholds: [TimeInterval],
        initialIndex: Int, initialRoundTripHint: TimeInterval? = nil,
        previousSampleWeight: Double = 0.8, currentSampleWeight: Double = 0.2,
        maximumSampleSeconds: TimeInterval? = nil, sampleUnitsPerSecond: Double = 1
    ) {
        precondition(!profiles.isEmpty && roundTripThresholds.count == profiles.count - 1)
        precondition(profiles.indices.contains(initialIndex))
        precondition(roundTripThresholds.allSatisfy { $0.isFinite && $0 > 0 })
        precondition(
            zip(roundTripThresholds, roundTripThresholds.dropFirst()).allSatisfy { pair in
                pair.0 < pair.1
            })
        precondition(previousSampleWeight >= 0 && previousSampleWeight < 1)
        precondition(currentSampleWeight > 0 && currentSampleWeight <= 1)
        precondition(abs(previousSampleWeight + currentSampleWeight - 1) < 1e-12)
        precondition(initialRoundTripHint.map { $0.isFinite && $0 > 0 } ?? true)
        precondition(maximumSampleSeconds.map { $0.isFinite && $0 > 0 } ?? true)
        precondition(sampleUnitsPerSecond.isFinite && sampleUnitsPerSecond > 0)
        self.profiles = profiles
        self.roundTripThresholds = roundTripThresholds
        self.initialIndex = initialIndex
        self.initialRoundTripHint = initialRoundTripHint
        self.previousSampleWeight = previousSampleWeight
        self.currentSampleWeight = currentSampleWeight
        self.maximumSampleSeconds = maximumSampleSeconds
        self.sampleUnitsPerSecond = sampleUnitsPerSecond
    }
}

/// Only acknowledged current-window work contributes to adaptation. The caller captures its
/// one-use preview ticket and admits the acknowledgement before updating this confined value.
public struct RelayPreviewPacing: Sendable {
    public let policy: RelayPreviewPacingPolicy
    public private(set) var profileIndex: Int
    public private(set) var observedRoundTripSeconds: TimeInterval?
    private var estimate: TimeInterval?
    public var currentProfile: RelayPreviewProfile { policy.profiles[profileIndex] }
    public init(policy: RelayPreviewPacingPolicy) {
        self.policy = policy
        profileIndex = policy.initialIndex
        estimate = policy.initialRoundTripHint.map { $0 * policy.sampleUnitsPerSecond }
    }
    @discardableResult public mutating func acknowledge(roundTripSeconds: TimeInterval)
        -> RelayPreviewProfile
    {
        acknowledgeInSampleUnits(roundTripSeconds * policy.sampleUnitsPerSecond)
    }
    /// Preserve an exercised producer's floating-point unit before smoothing, including ms.
    @discardableResult public mutating func acknowledgeInSampleUnits(_ sample: Double)
        -> RelayPreviewProfile
    {
        let roundTripSeconds = sample / policy.sampleUnitsPerSecond
        guard roundTripSeconds.isFinite && roundTripSeconds > 0,
            policy.maximumSampleSeconds.map({ roundTripSeconds < $0 }) ?? true
        else { return currentProfile }
        let value =
            estimate.map {
                $0 * policy.previousSampleWeight + sample * policy.currentSampleWeight
            } ?? sample
        estimate = value
        observedRoundTripSeconds = value / policy.sampleUnitsPerSecond
        profileIndex =
            policy.roundTripThresholds.filter { value >= $0 * policy.sampleUnitsPerSecond }.count
        return currentProfile
    }
    @discardableResult public mutating func timedOut() -> RelayPreviewProfile {
        profileIndex = min(profileIndex + 1, policy.profiles.count - 1)
        estimate = nil
        observedRoundTripSeconds = nil
        return currentProfile
    }
    public mutating func reset() {
        profileIndex = policy.initialIndex
        estimate = policy.initialRoundTripHint.map { $0 * policy.sampleUnitsPerSecond }
        observedRoundTripSeconds = nil
    }
}

/// Capability reachability is not live monitor evidence. An authoritative state receipt owns
/// freshness, including refusal when the supplied monotonic clock moves behind that receipt.
public struct RelayWatchFreshness: Sendable {
    public let maximumAgeSeconds: TimeInterval
    private var acceptedAt: TimeInterval?
    public init(maximumAgeSeconds: TimeInterval) {
        precondition(maximumAgeSeconds.isFinite && maximumAgeSeconds > 0)
        self.maximumAgeSeconds = maximumAgeSeconds
    }
    public mutating func accept(at now: TimeInterval) { acceptedAt = now }
    public mutating func clear() { acceptedAt = nil }
    public func isFresh(at now: TimeInterval) -> Bool {
        guard let acceptedAt else { return false }
        let age = now - acceptedAt
        return age >= 0 && age < maximumAgeSeconds
    }
    public func remainingSeconds(at now: TimeInterval) -> TimeInterval? {
        acceptedAt.map { max(0, maximumAgeSeconds - max(0, now - $0)) }
    }
}

/// Node/request/source retirement is checked together; a late result is never accepted merely
/// because a phone with the same name or address is reachable again.
public struct RelayWatchPendingCommand: Equatable, Sendable {
    public let peer: String
    public let request: UInt64
    public let source: UUID
    public init(peer: String, request: UInt64, source: UUID) {
        self.peer = peer
        self.request = request
        self.source = source
    }
    public func matches(peer: String, request: UInt64, source: UUID) -> Bool {
        self.peer == peer && self.request == request && self.source == source
    }
}

public struct RelayWatchFrameSequence: Sendable {
    private var latestRequest: UInt64 = 0
    public init() {}
    public mutating func accept(_ request: UInt64) -> Bool {
        guard request > latestRequest else { return false }
        latestRequest = request
        return true
    }
    public mutating func clear() { latestRequest = 0 }
}

/// Latest-wins admission confined to the operator actor. Native image recycle/dispatch ports
/// run after the owner's reservation state is coherent, including synchronous port reentry.
@MainActor public final class RelayLatestPreviewPump<Value: Sendable> {
    public struct Dispatch: Sendable {
        public let value: Value
        public let token: UInt64
    }
    private var reservations: RelayPreviewReservations
    private let releasingOutstandingOnInvalidate: Bool
    private let dispatch: @MainActor (Dispatch) -> Void
    private let onDiscard: @MainActor (Value) -> Void
    private var tickets: [UInt64: RelayPreviewReservations.Ticket] = [:]
    private var latest: Value?
    public init(
        maximumInFlight: Int = 1, releasingOutstandingOnInvalidate: Bool = true,
        dispatch: @escaping @MainActor (Dispatch) -> Void,
        onDiscard: @escaping @MainActor (Value) -> Void = { _ in }
    ) {
        reservations = RelayPreviewReservations(maximumInFlight: maximumInFlight)
        self.releasingOutstandingOnInvalidate = releasingOutstandingOnInvalidate
        self.dispatch = dispatch
        self.onDiscard = onDiscard
    }
    public func offer(_ value: Value) {
        guard let ticket = reservations.reserve() else {
            let discarded = latest
            latest = value
            if let discarded { onDiscard(discarded) }
            return
        }
        tickets[ticket.sequence] = ticket
        dispatch(Dispatch(value: value, token: ticket.sequence))
    }
    public func complete(_ token: UInt64) {
        guard let ticket = tickets.removeValue(forKey: token), reservations.complete(ticket) else {
            return
        }
        guard let pending = latest else { return }
        latest = nil
        offer(pending)
    }
    public func invalidate() {
        let discarded = latest
        latest = nil
        if releasingOutstandingOnInvalidate { tickets.removeAll() }
        reservations.invalidate(releasingOutstanding: releasingOutstandingOnInvalidate)
        if let discarded { onDiscard(discarded) }
    }
    public var isBusy: Bool { reservations.inFlightCount > 0 || latest != nil }
    public func isActive(_ token: UInt64) -> Bool {
        tickets[token].map(reservations.isCurrent) == true
    }
}
