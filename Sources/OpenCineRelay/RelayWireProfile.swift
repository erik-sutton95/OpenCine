import Foundation

/// Immutable deployment facts. A profile describes an existing wire, not a camera brand or
/// command feature inventory. Hosts and browsers use the supplied service/TXT/presence values.
public struct RelayWireProfile: Equatable, Sendable {
    public let serviceType: String
    public let version: Int
    public let maximumPayloadBytes: Int
    public let servedCameraTXTKey: String
    public let watchableTXTKey: String
    public let presenceTCPPort: UInt16?
    public let jpegCodec: Int?
    public let hevcCodec: Int
    public let acceptsPeerCodecDeclaration: Bool
    public let messageKinds: Set<UInt8>

    public init(
        serviceType: String, version: Int, maximumPayloadBytes: Int = 8 * 1024 * 1024,
        servedCameraTXTKey: String, watchableTXTKey: String, presenceTCPPort: UInt16? = nil,
        jpegCodec: Int? = nil, hevcCodec: Int = 1, acceptsPeerCodecDeclaration: Bool = false,
        messageKinds: Set<UInt8> = [0x01, 0x02, 0x03, 0x04, 0x05, 0x10, 0x11, 0x12]
    ) {
        precondition(maximumPayloadBytes >= 0 && maximumPayloadBytes < Int(UInt32.max))
        self.serviceType = serviceType
        self.version = version
        self.maximumPayloadBytes = maximumPayloadBytes
        self.servedCameraTXTKey = servedCameraTXTKey
        self.watchableTXTKey = watchableTXTKey
        self.presenceTCPPort = presenceTCPPort
        self.jpegCodec = jpegCodec
        self.hevcCodec = hevcCodec
        self.acceptsPeerCodecDeclaration = acceptsPeerCodecDeclaration
        self.messageKinds = messageKinds
    }

    /// Existing OpenCine shared monitor deployment, unchanged for its v1 peers.
    public static let sharedMonitor = RelayWireProfile(
        serviceType: WatcherRelayProtocol.serviceType, version: WatcherRelayProtocol.version,
        maximumPayloadBytes: WatcherRelayProtocol.maximumPayloadBytes,
        servedCameraTXTKey: WatcherRelayProtocol.txtCamera,
        watchableTXTKey: WatcherRelayProtocol.txtWatchable,
        hevcCodec: WatcherRelayProtocol.hevcCodec)
}

/// Socket/radio facts supplied by the host. The existing shared path prohibits cellular and
/// peer-to-peer; a deployment that exercises AWDL supplies its original values explicitly.
public struct RelayNetworkPolicy: Equatable, Sendable {
    public let includePeerToPeer: Bool
    public let prohibitsCellular: Bool
    public let keepaliveIdle: Int
    public let keepaliveInterval: Int
    public let keepaliveCount: Int

    public init(
        includePeerToPeer: Bool = false, prohibitsCellular: Bool = true,
        keepaliveIdle: Int = 10, keepaliveInterval: Int = 5, keepaliveCount: Int = 3
    ) {
        self.includePeerToPeer = includePeerToPeer
        self.prohibitsCellular = prohibitsCellular
        self.keepaliveIdle = keepaliveIdle
        self.keepaliveInterval = keepaliveInterval
        self.keepaliveCount = keepaliveCount
    }
}
