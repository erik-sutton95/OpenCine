import Foundation

/// Where an observed value came from. An image estimate never stands in for a camera report.
public enum ObservationOrigin: String, Hashable, Codable, Sendable {
    case cameraReported
    case protocolDerived
    case imageEstimated
    case clockDerived
    case operatorProvided
    case unknown
}

public enum ObservationValidity: Hashable, Codable, Sendable {
    case valid
    /// The value is kept for display but its assumptions no longer hold.
    case invalid(reason: String)
}

/// Only where meaningful. There are no uncalibrated confidence scores.
public enum ObservationPrecision: Hashable, Codable, Sendable {
    case exact
    /// The source reports in steps of this size, for example 0.25 for a four-bar battery.
    case quantized(step: Double)
    case approximate(plusOrMinus: Double)
}

public enum Freshness: Hashable, Sendable {
    case fresh
    case stale
    /// No value or no timestamp, so age cannot be known.
    case unknown
}

/// One observed value with its provenance.
///
/// `value == nil` is unknown, whatever else is set. Unknown is never `false`, `0` or `""`:
/// an unknown battery is not empty, unknown recording is not idle, unknown charging is not
/// unplugged. Freshness is computed against a caller-supplied `now` instead of being stored, so
/// a retained snapshot cannot claim to be fresh forever.
public struct Observation<Value: Sendable>: Sendable {
    public var value: Value?
    public var origin: ObservationOrigin
    public var observedAt: MonotonicInstant?
    public var validity: ObservationValidity
    public var precision: ObservationPrecision?

    public init(
        _ value: Value, origin: ObservationOrigin, at observedAt: MonotonicInstant?,
        validity: ObservationValidity = .valid, precision: ObservationPrecision? = nil
    ) {
        self.value = value
        self.origin = origin
        self.observedAt = observedAt
        self.validity = validity
        self.precision = precision
    }

    private init() {
        value = nil
        origin = .unknown
        observedAt = nil
        validity = .valid
        precision = nil
    }

    public static var unknown: Self { Self() }

    public var isKnown: Bool { value != nil }

    public func freshness(at now: MonotonicInstant, maxAge: Duration) -> Freshness {
        guard value != nil, let observedAt else { return .unknown }
        return now - observedAt <= maxAge ? .fresh : .stale
    }
}

extension Observation: Equatable where Value: Equatable {}
extension Observation: Hashable where Value: Hashable {}
extension Observation: Codable where Value: Codable {}
