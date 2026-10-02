import Foundation

/// One saved way to reach a camera (a "setup"). Dates are epoch milliseconds in stored JSON.
public struct SavedRoute: Hashable, Codable, Sendable, Identifiable {
    /// Minted once and kept in the saved document.
    public var id: ConnectionRouteID
    /// Codec-stable identity within the camera, for example `ap`, `wifi`, `hotspot`.
    public var key: String
    public var kind: RouteKind
    /// The operator's setup name; `nil` uses the shell's title for the kind.
    public var title: String?
    /// Network name (SSID) or interface name. Never a secret.
    public var network: String?
    /// Needs Bluetooth commissioning before the route comes up.
    public var bluetooth: Bool
    public var lastConnected: Date?
    /// Integration-owned values, kept verbatim.
    public var extras: [String: String]

    public init(
        id: ConnectionRouteID = .init(), key: String, kind: RouteKind, title: String? = nil,
        network: String? = nil, bluetooth: Bool = false, lastConnected: Date? = nil,
        extras: [String: String] = [:]
    ) {
        self.id = id
        self.key = key
        self.kind = kind
        self.title = title
        self.network = network
        self.bluetooth = bluetooth
        self.lastConnected = lastConnected
        self.extras = extras
    }
}

/// One saved camera with its routes.
public struct SavedCamera: Hashable, Codable, Sendable, Identifiable {
    /// Stable local key. A migrated camera keeps its legacy record id verbatim, so credentials,
    /// media and calibration keyed by it keep working.
    public var id: String
    public var integration: IntegrationID
    /// Durable identity when known (a serial); never derived from a host or a name.
    public var device: CameraDeviceID?
    /// The operator's rename.
    public var name: String?
    public var advertisedName: String
    public var model: String
    /// In chip order.
    public var routes: [SavedRoute]
    public var preferredRoute: ConnectionRouteID?
    public var lastConnected: Date?
    /// Integration-owned values, kept verbatim.
    public var extras: [String: String]

    public init(
        id: String, integration: IntegrationID, device: CameraDeviceID? = nil, name: String? = nil,
        advertisedName: String, model: String, routes: [SavedRoute] = [],
        preferredRoute: ConnectionRouteID? = nil, lastConnected: Date? = nil,
        extras: [String: String] = [:]
    ) {
        self.id = id
        self.integration = integration
        self.device = device
        self.name = name
        self.advertisedName = advertisedName
        self.model = model
        self.routes = routes
        self.preferredRoute = preferredRoute
        self.lastConnected = lastConnected
        self.extras = extras
    }

    /// The rename, else the advertised name.
    public var displayName: String { name ?? advertisedName }
}
