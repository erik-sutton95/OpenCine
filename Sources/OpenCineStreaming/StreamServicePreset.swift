import Foundation

/// One streaming service: where it ingests, what it accepts, and where the user finds a key.
///
/// The service names below are preset content, never a branch condition. Every service fact lives
/// in this one table (sources and dates in `docs/streaming/services.md`), so a service change
/// needs no change anywhere else.
public struct StreamServicePreset: Hashable, Sendable, Identifiable {
    public enum Aspect: Hashable, Sendable {
        case landscape16x9
        case portrait9x16
    }

    public var id: String
    public var displayName: String
    /// The fixed ingest address, or `nil` when the user enters it.
    public var serverURL: String?
    /// The user enters the server address, because the service issues it with the key.
    public var requiresServerEntry: Bool
    /// The most the service accepts, or `nil` for no stated cap.
    public var maxVideoBitrateBps: Int?
    public var aspect: Aspect
    /// One plain sentence on where to find the stream key.
    public var keyHint: String

    public init(
        id: String, displayName: String, serverURL: String?, requiresServerEntry: Bool,
        maxVideoBitrateBps: Int?, aspect: Aspect, keyHint: String
    ) {
        self.id = id
        self.displayName = displayName
        self.serverURL = serverURL
        self.requiresServerEntry = requiresServerEntry
        self.maxVideoBitrateBps = maxVideoBitrateBps
        self.aspect = aspect
        self.keyHint = keyHint
    }
}

public extension StreamServicePreset {
    /// The services with a preset, in the order a picker shows them. `custom` follows them.
    static let all: [StreamServicePreset] = [
        StreamServicePreset(
            id: "twitch", displayName: "Twitch",
            serverURL: "rtmps://ingest.global-contribute.live-video.net/app", requiresServerEntry: false,
            maxVideoBitrateBps: 6_000_000, aspect: .landscape16x9,
            keyHint: "In Twitch, open Creator Dashboard, Settings, Stream, and copy the Primary Stream key."),
        StreamServicePreset(
            id: "youtube", displayName: "YouTube",
            serverURL: "rtmps://a.rtmps.youtube.com/live2", requiresServerEntry: false,
            maxVideoBitrateBps: nil, aspect: .landscape16x9,
            keyHint: "In YouTube Studio, choose Create, Go live, then the Stream tab, and copy the stream key."),
        StreamServicePreset(
            id: "facebook", displayName: "Facebook",
            serverURL: "rtmps://rtmp-api.facebook.com:443/rtmp/", requiresServerEntry: false,
            maxVideoBitrateBps: 6_000_000, aspect: .landscape16x9,
            keyHint: "In Facebook Live Producer, choose Streaming software and copy the stream key."),
        StreamServicePreset(
            id: "instagram", displayName: "Instagram",
            serverURL: nil, requiresServerEntry: true,
            maxVideoBitrateBps: 6_000_000, aspect: .portrait9x16,
            keyHint: "On instagram.com, choose Create, then Live, and copy both the stream URL and the stream key; they change every time."),
    ]

    /// Any other `rtmps://` server: the user enters the address and the key.
    static let custom = StreamServicePreset(
        id: "custom", displayName: "Custom server",
        serverURL: nil, requiresServerEntry: true,
        maxVideoBitrateBps: nil, aspect: .landscape16x9,
        keyHint: "Your streaming service shows the server address and stream key together; paste both.")
}
