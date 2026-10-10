import Foundation

/// The common handshake facts. Absent codec declarations retain the deployed legacy meaning;
/// a wire that never negotiated codecs omits that optional key when encoding.
public struct RelayPeerHello: Codable, Equatable, Sendable {
    public let version: Int
    public let hostName: String
    public let cameraName: String?
    public let passcode: String?
    public let codecs: [String]?
    public let watcherID: String?

    public init(
        version: Int, hostName: String, cameraName: String? = nil, passcode: String? = nil,
        codecs: [String]? = nil, watcherID: String? = nil
    ) {
        self.version = version
        self.hostName = hostName
        self.cameraName = cameraName
        self.passcode = passcode
        self.codecs = codecs
        self.watcherID = watcherID
    }

    public var acceptsHEVC: Bool { codecs?.contains("hevc") ?? true }
}

/// Video facts used by the shared reference-chain/backpressure owner. Remaining readings stay
/// in the codec's exact typed frame payload, without vendor feature cases in shared policy.
public struct RelayVideoDescription: Equatable, Sendable {
    public let codec: Int
    public let isKeyframe: Bool
    public let parameterSets: [Data]?

    public init(codec: Int, isKeyframe: Bool, parameterSets: [Data]?) {
        self.codec = codec
        self.isKeyframe = isKeyframe
        self.parameterSets = parameterSets
    }
}

/// Two deployed wires can carry different typed state/command/readings while one runtime owns
/// socket, peer, authorization, lease and frame lifetime. Integration-owned command types remain
/// integration-owned; the admitted callback receives that exact typed value.
public protocol RelayWireCodec: Sendable {
    associatedtype State: Codable & Sendable
    associatedtype FrameMetadata: Codable & Sendable
    associatedtype Command: Codable & Sendable
    associatedtype ControlToken: Codable & Equatable & Sendable
    associatedtype JoinDenied: Codable & Sendable

    var profile: RelayWireProfile { get }
    func videoDescription(of metadata: FrameMetadata) -> RelayVideoDescription
    func controlToken(holderName: String, holderIsRecipient: Bool) -> ControlToken
    func joinDenied(reason: String, passcodeRequired: Bool) -> JoinDenied
}

extension RelayWireCodec {
    public func encodeHello(_ value: RelayPeerHello) throws -> Data {
        let hello = RelayPeerHello(
            version: value.version, hostName: value.hostName, cameraName: value.cameraName,
            passcode: value.passcode,
            codecs: profile.acceptsPeerCodecDeclaration ? value.codecs : nil,
            watcherID: value.watcherID)
        return try JSONEncoder().encode(hello)
    }

    public func decodeHello(_ payload: Data) throws -> RelayPeerHello {
        let value = try JSONDecoder().decode(RelayPeerHello.self, from: payload)
        return RelayPeerHello(
            version: value.version, hostName: value.hostName,
            cameraName: value.cameraName, passcode: value.passcode,
            codecs: profile.acceptsPeerCodecDeclaration ? value.codecs : nil,
            watcherID: value.watcherID)
    }

    public func encodeState(_ state: State) throws -> Data { try JSONEncoder().encode(state) }
    public func decodeState(_ payload: Data) throws -> State {
        try JSONDecoder().decode(State.self, from: payload)
    }
    public func encodeCommand(_ command: Command) throws -> Data {
        try JSONEncoder().encode(command)
    }
    public func decodeCommand(_ payload: Data) throws -> Command {
        try JSONDecoder().decode(Command.self, from: payload)
    }

    public func encodeFrame(metadata: FrameMetadata, image: Data) throws -> Data {
        try RelayFrameBlob.encode(metadata: metadata, image: image)
    }

    public func decodeFrame(_ payload: Data) throws -> (metadata: FrameMetadata, image: Data) {
        try RelayFrameBlob.decode(FrameMetadata.self, from: payload)
    }
}

/// The existing shared v1 wire's real adapter. Fields and encoded command cases stay unchanged.
public struct SharedMonitorRelayCodec: RelayWireCodec {
    public typealias State = WatcherRelayState
    public typealias FrameMetadata = WatcherRelayFrameMetadata
    public typealias Command = WatcherRelayCommand
    public typealias ControlToken = WatcherRelayControlToken
    public typealias JoinDenied = WatcherRelayJoinDenied
    public let profile = RelayWireProfile.sharedMonitor

    public init() {}

    public func videoDescription(of metadata: FrameMetadata) -> RelayVideoDescription {
        RelayVideoDescription(
            codec: metadata.codec, isKeyframe: metadata.isKeyframe,
            parameterSets: metadata.parameterSets)
    }

    public func controlToken(holderName: String, holderIsRecipient: Bool) -> ControlToken {
        ControlToken(holderName: holderName, holderIsRecipient: holderIsRecipient)
    }
    public func joinDenied(reason: String, passcodeRequired: Bool) -> JoinDenied {
        JoinDenied(reason: reason, passcodeRequired: passcodeRequired)
    }
}
