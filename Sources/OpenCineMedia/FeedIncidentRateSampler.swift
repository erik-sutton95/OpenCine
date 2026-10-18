import Foundation

/// Identity of the measured counters, separate from the logical incident session.
public struct FeedIncidentCounterEpoch: Equatable, Sendable {
    public var decoderGeneration: Int?
    public var socketGeneration: Int?
    public var processedPresentation: Bool?
    public init(
        decoderGeneration: Int? = nil, socketGeneration: Int? = nil,
        processedPresentation: Bool? = nil
    ) {
        self.decoderGeneration = decoderGeneration
        self.socketGeneration = socketGeneration
        self.processedPresentation = processedPresentation
    }
}

/// Cumulative counts in one producer lifetime. An unavailable stage has no count.
public struct FeedIncidentStageCounts: Equatable, Sendable {
    public var packet: Int?
    public var accessUnit: Int?
    public var decodeSubmit: Int?
    public var decodeAccept: Int?
    public var decodedOutput: Int?
    public var assistOutput: Int?
    public var present: Int?
    public var ack: Int?

    public init(
        packet: Int? = nil, accessUnit: Int? = nil, decodeSubmit: Int? = nil,
        decodeAccept: Int? = nil, decodedOutput: Int? = nil, assistOutput: Int? = nil,
        present: Int? = nil, ack: Int? = nil
    ) {
        self.packet = packet
        self.accessUnit = accessUnit
        self.decodeSubmit = decodeSubmit
        self.decodeAccept = decodeAccept
        self.decodedOutput = decodedOutput
        self.assistOutput = assistOutput
        self.present = present
        self.ack = ack
    }
}

/// Observed rates distinguish unavailable intervals from measured zero. The original numeric
/// rates remain a compatibility projection for existing policy and callers.
public struct FeedIncidentRateObservation: Equatable, Sendable, Codable {
    public var packetHz: Double?
    public var accessUnitHz: Double?
    public var decodeSubmitHz: Double?
    public var decodeAcceptHz: Double?
    public var decodedOutputHz: Double?
    public var assistOutputHz: Double?
    public var presentHz: Double?
    public var ackHz: Double?

    public init(
        packetHz: Double? = nil, accessUnitHz: Double? = nil, decodeSubmitHz: Double? = nil,
        decodeAcceptHz: Double? = nil, decodedOutputHz: Double? = nil,
        assistOutputHz: Double? = nil,
        presentHz: Double? = nil, ackHz: Double? = nil
    ) {
        self.packetHz = packetHz
        self.accessUnitHz = accessUnitHz
        self.decodeSubmitHz = decodeSubmitHz
        self.decodeAcceptHz = decodeAcceptHz
        self.decodedOutputHz = decodedOutputHz
        self.assistOutputHz = assistOutputHz
        self.presentHz = presentHz
        self.ackHz = ackHz
    }

    public var rates: FeedIncidentRates {
        FeedIncidentRates(
            packetHz: packetHz ?? 0, accessUnitHz: accessUnitHz ?? 0,
            decodeSubmitHz: decodeSubmitHz ?? 0, decodeAcceptHz: decodeAcceptHz ?? 0,
            decodedOutputHz: decodedOutputHz ?? 0, assistOutputHz: assistOutputHz ?? 0,
            presentHz: presentHz ?? 0, ackHz: ackHz ?? 0, observed: self)
    }
}

/// Call under the producer's existing serialization. Reset when its counter owner changes.
public struct FeedIncidentRateSampler: Sendable {
    private var previous: (at: TimeInterval, counts: FeedIncidentStageCounts)?
    private var epoch: FeedIncidentCounterEpoch?
    public init() {}
    public mutating func reset() {
        previous = nil
        epoch = nil
    }

    public mutating func sample(
        now: TimeInterval, counts: FeedIncidentStageCounts,
        epoch nextEpoch: FeedIncidentCounterEpoch? = nil
    ) -> FeedIncidentRates {
        if epoch != nextEpoch {
            previous = nil
            epoch = nextEpoch
        }
        guard now.isFinite, now >= 0 else { return FeedIncidentRateObservation().rates }
        let prior = previous
        // Out-of-order or duplicate readings cannot replace the latest valid baseline.
        if let prior, now <= prior.at { return FeedIncidentRateObservation().rates }
        previous = (now, counts)
        guard let prior else { return FeedIncidentRateObservation().rates }
        let elapsed = now - prior.at
        func rate(_ current: Int?, _ old: Int?) -> Double? {
            guard let current, let old, old >= 0, current >= old else { return nil }
            let value = Double(current - old) / elapsed
            return value.isFinite ? value : nil
        }
        return FeedIncidentRateObservation(
            packetHz: rate(counts.packet, prior.counts.packet),
            accessUnitHz: rate(counts.accessUnit, prior.counts.accessUnit),
            decodeSubmitHz: rate(counts.decodeSubmit, prior.counts.decodeSubmit),
            decodeAcceptHz: rate(counts.decodeAccept, prior.counts.decodeAccept),
            decodedOutputHz: rate(counts.decodedOutput, prior.counts.decodedOutput),
            assistOutputHz: rate(counts.assistOutput, prior.counts.assistOutput),
            presentHz: rate(counts.present, prior.counts.present),
            ackHz: rate(counts.ack, prior.counts.ack)
        ).rates
    }

    /// Both values must belong to the same clock domain. Future and invalid stamps are unknown.
    public static func age(since stamp: TimeInterval?, now: TimeInterval) -> TimeInterval? {
        guard let stamp, now.isFinite, stamp.isFinite, stamp <= now else { return nil }
        let age = now - stamp
        return age.isFinite ? age : nil
    }

    public static func age(since stamp: Date?, now: Date) -> TimeInterval? {
        age(since: stamp?.timeIntervalSinceReferenceDate, now: now.timeIntervalSinceReferenceDate)
    }
}
