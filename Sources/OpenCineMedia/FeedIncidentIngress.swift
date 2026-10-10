import Foundation

/// Current endpoint receive/admission facts, sampled with the existing incident timeline.
/// Raw counts describe socket callbacks, not RF delivery. Registration is a local submission,
/// not proof of peer receipt. A missing object means this producer does not expose these facts.
public struct FeedIncidentIngress: Equatable, Sendable, Codable {
    public var socketGeneration: Int
    public var receivedDatagrams: Int
    public var videoDatagrams: Int
    public var videoGateDrops: Int
    public var injectedVideoDrops: Int
    public var registrationSubmissions: Int
    public var receiveErrors: Int
    public var lastDatagramAge: TimeInterval?
    public var lastVideoDatagramAge: TimeInterval?
    public var lastRegistrationSubmissionAge: TimeInterval?
    public var videoGateOpen: Bool

    public init(
        socketGeneration: Int, receivedDatagrams: Int, videoDatagrams: Int,
        videoGateDrops: Int, injectedVideoDrops: Int, registrationSubmissions: Int,
        receiveErrors: Int, lastDatagramAge: TimeInterval?, lastVideoDatagramAge: TimeInterval?,
        lastRegistrationSubmissionAge: TimeInterval?, videoGateOpen: Bool
    ) {
        self.socketGeneration = max(0, socketGeneration)
        self.receivedDatagrams = max(0, receivedDatagrams)
        self.videoDatagrams = max(0, videoDatagrams)
        self.videoGateDrops = max(0, videoGateDrops)
        self.injectedVideoDrops = max(0, injectedVideoDrops)
        self.registrationSubmissions = max(0, registrationSubmissions)
        self.receiveErrors = max(0, receiveErrors)
        self.lastDatagramAge = FeedIncidentPrivacy.age(lastDatagramAge)
        self.lastVideoDatagramAge = FeedIncidentPrivacy.age(lastVideoDatagramAge)
        self.lastRegistrationSubmissionAge = FeedIncidentPrivacy.age(lastRegistrationSubmissionAge)
        self.videoGateOpen = videoGateOpen
    }
}

/// Fixed-size accounting. The native producer supplies its monotonic clock and serializes access.
/// Retired callbacks cannot change a successor's counts or make its receive age fresh.
public struct FeedIngressMetrics: Sendable {
    public enum Event: Sendable {
        case datagram(video: Bool)
        case videoGateDrop
        case injectedVideoDrop
        case registrationSubmission
        case receiveError
    }

    private var generation: Int
    private var datagrams = 0
    private var video = 0
    private var gateDrops = 0
    private var injectedDrops = 0
    private var registrations = 0
    private var errors = 0
    private var lastDatagram: TimeInterval?
    private var lastVideo: TimeInterval?
    private var lastRegistration: TimeInterval?

    public init(generation: Int = 0) { self.generation = generation }

    public mutating func reset(generation: Int) { self = Self(generation: generation) }

    public mutating func record(_ event: Event, at now: TimeInterval, generation: Int) {
        guard generation == self.generation, now.isFinite, now >= 0 else { return }
        switch event {
        case .datagram(let isVideo):
            datagrams += 1
            lastDatagram = now
            if isVideo { video += 1; lastVideo = now }
        case .videoGateDrop: gateDrops += 1
        case .injectedVideoDrop: injectedDrops += 1
        case .registrationSubmission:
            registrations += 1
            lastRegistration = now
        case .receiveError: errors += 1
        }
    }

    public func snapshot(now: TimeInterval, videoGateOpen: Bool) -> FeedIncidentIngress {
        func age(_ stamp: TimeInterval?) -> TimeInterval? {
            guard let stamp, now.isFinite, now >= stamp else { return nil }
            return now - stamp
        }
        return FeedIncidentIngress(
            socketGeneration: generation, receivedDatagrams: datagrams, videoDatagrams: video,
            videoGateDrops: gateDrops, injectedVideoDrops: injectedDrops,
            registrationSubmissions: registrations, receiveErrors: errors,
            lastDatagramAge: age(lastDatagram), lastVideoDatagramAge: age(lastVideo),
            lastRegistrationSubmissionAge: age(lastRegistration), videoGateOpen: videoGateOpen)
    }
}
