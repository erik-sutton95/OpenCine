import Foundation

/// Local scheduling and presentation actions. Their deployed representation stays in the codec.
public enum RelayWatchAction: Equatable, Sendable {
    case toggleRecord
    case capture
    case resume
}

public struct RelayWatchSourceFacts: Equatable, Sendable {
    public enum Connection: Equatable, Sendable { case disconnected, connected, noCamera }
    public let connection: Connection
    public let feedLive: Bool
    public init(connection: Connection, feedLive: Bool) {
        self.connection = connection
        self.feedLive = feedLive
    }
}

/// Two independently deployed Watch schemas use the same lifetime and envelope owner. Payload
/// projections are typed codec facts; neither camera names nor a manufacturer choose policy.
public protocol RelayWatchCodec: Sendable {
    associatedtype State: Codable, Equatable, Sendable
    associatedtype Frame: Codable, Sendable
    associatedtype Command: Codable, Sendable
    associatedtype Result: Codable, Sendable
    associatedtype Timecode: Sendable
    func stateMatches(_ lhs: State, _ rhs: State) -> Bool
    func sourceFacts(_ state: State) -> RelayWatchSourceFacts
    func isRecording(_ state: State) -> Bool
    func replacing(_ state: State, with result: Result) -> State
    func imageBytes(_ frame: Frame) -> Data
    func timecode(_ frame: Frame) -> Timecode
    func command(_ action: RelayWatchAction) -> Command
    func action(_ command: Command) -> RelayWatchAction
    func result(accepted: Bool, isRecording: Bool, error: String?) -> Result
    func error(_ result: Result) -> String?
}

public enum RelayWatchEnvelope: Sendable {
    public enum Kind: UInt8, Sendable {
        case state = 0x01, frame = 0x02, command = 0x10, result = 0x11
    }
    public static func kind(_ data: Data) throws -> Kind {
        let raw = try RelayEnvelopeFraming.kind(of: data, admittedKinds: [1, 2, 16, 17])
        guard let kind = Kind(rawValue: raw) else {
            throw RelayEnvelopeFraming.DecodeError.unknownKind(raw)
        }
        return kind
    }
    public static func encode<Value: Encodable>(_ value: Value, kind: Kind) throws -> Data {
        try RelayEnvelopeFraming.encode(kind: kind.rawValue, payload: value)
    }
    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        try RelayEnvelopeFraming.decode(type, from: data)
    }
}

public struct WatchRelayCodec: RelayWatchCodec {
    public init() {}
    public func stateMatches(_ lhs: WatchRelayState, _ rhs: WatchRelayState) -> Bool {
        lhs.matchesIgnoringLiveReadouts(rhs)
    }
    public func sourceFacts(_ state: WatchRelayState) -> RelayWatchSourceFacts {
        let connection: RelayWatchSourceFacts.Connection
        switch state.connection {
        case .disconnected: connection = .disconnected
        case .connected: connection = .connected
        case .noCamera: connection = .noCamera
        }
        return .init(connection: connection, feedLive: state.feedLive)
    }
    public func isRecording(_ state: WatchRelayState) -> Bool { state.isRecording }
    public func replacing(_ state: WatchRelayState, with result: WatchCommandResult) -> WatchRelayState {
        state.replacing(isRecording: result.isRecording)
    }
    public func imageBytes(_ frame: WatchRelayFrame) -> Data { frame.jpeg }
    public func timecode(_ frame: WatchRelayFrame) -> String { frame.timecode }
    public func command(_ action: RelayWatchAction) -> WatchRelayCommand {
        switch action {
        case .toggleRecord: .toggleRecord
        case .capture: .capture
        case .resume: .resume
        }
    }
    public func action(_ command: WatchRelayCommand) -> RelayWatchAction {
        switch command {
        case .toggleRecord: .toggleRecord
        case .capture: .capture
        case .resume: .resume
        }
    }
    public func result(accepted: Bool, isRecording: Bool, error: String?) -> WatchCommandResult {
        .init(accepted: accepted, isRecording: isRecording, error: error)
    }
    public func error(_ result: WatchCommandResult) -> String? { result.error }
}

@MainActor public protocol RelayWatchScheduled: AnyObject {
    func cancel()
}

@MainActor public protocol RelayWatchScheduler: AnyObject {
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void)
        -> any RelayWatchScheduled
}

public struct RelayWatchPhonePolicy: Sendable {
    public enum StateDelivery: Equatable, Sendable { case reachableMessage, contextAndMessage }
    public let pacing: RelayPreviewPacingPolicy
    public let stateDelivery: StateDelivery
    public let maximumInFlight: Int
    public let releasesOutstandingOnRetirement: Bool
    public init(
        pacing: RelayPreviewPacingPolicy, stateDelivery: StateDelivery,
        maximumInFlight: Int = 3, releasesOutstandingOnRetirement: Bool
    ) {
        precondition(maximumInFlight > 0)
        self.pacing = pacing
        self.stateDelivery = stateDelivery
        self.maximumInFlight = maximumInFlight
        self.releasesOutstandingOnRetirement = releasesOutstandingOnRetirement
    }
}
