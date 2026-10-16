import OpenCineCore

/// A shared network the station-network wizard offers, prefills or joins: a router or venue
/// Wi-Fi, or this phone's hotspot. The app keeps where it is stored.
public struct StationNetwork: Equatable, Sendable {
    public var ssid: String
    public var password: String
    public var hotspot: Bool

    public init(ssid: String, password: String, hotspot: Bool) {
        self.ssid = ssid
        self.password = password
        self.hotspot = hotspot
    }
}

/// The brand words and camera-network naming the station-network wizard shows. Values only.
public struct StationNetworkBrand: Equatable, Sendable {
    /// The app's name as Settings lists it ("Settings › <appName> › Location").
    public var appName: String
    /// The camera family the 2.4 GHz note names ("every <cameraFamily> camera").
    public var cameraFamily: String
    /// Lowercased prefix of the cameras' own access points, never offered as a shared network.
    public var cameraNetworkPrefix: String

    public init(appName: String, cameraFamily: String, cameraNetworkPrefix: String) {
        self.appName = appName
        self.cameraFamily = cameraFamily
        self.cameraNetworkPrefix = cameraNetworkPrefix
    }
}

/// Whom the station-network wizard sets up: one saved camera, or the Multiview session.
public enum StationNetworkSetupContext: Sendable {
    case camera(SavedCamera)
    case multiview

    public var camera: SavedCamera? {
        if case .camera(let camera) = self { return camera }
        return nil
    }
    public var prefix: String { camera == nil ? "multiview.setup" : "addSetup" }
    public var title: String { camera == nil ? "Connect your cameras" : "Add setup" }
    public var networkHint: String {
        camera == nil
            ? "This iPhone joins first. Every camera you add will use the same Wi-Fi."
            : "The camera and this iPhone must be on the same Wi-Fi."
    }
}

/// The station-network wizard's rules, apart from its view: chooser copy and which names count
/// as camera or phone networks.
public enum StationNetworkSetupRules {
    /// Host copy and supported station routes; the app keeps network and credential steps.
    public static func setupChooser(context: StationNetworkSetupContext) -> AddSetupChooser {
        func detail(_ kind: RouteKind, _ body: String, _ tag: String) -> String {
            [context.camera.flatMap { network($0, kind) }.map { "Added · \($0)" }, body, tag]
                .compactMap { $0 }.joined(separator: "\n")
        }
        return AddSetupChooser(
            title: context.camera == nil
                ? "How will your cameras connect?" : "How should this camera connect?",
            detail: context.camera.map { "\($0.displayName) · \($0.model)" } ?? "",
            options: [
                AddSetupOption(
                    id: "wifi", kind: .infrastructureNetwork,
                    title: "Wi-Fi",
                    detail: detail(
                        .infrastructureNetwork,
                        "A router, venue network or another device’s hotspot. Cameras and this iPhone join the same Wi-Fi.",
                        "Best for studios and several cameras"),
                    actionTitle: "Choose Wi-Fi"),
                AddSetupOption(
                    id: "phoneHotspot", kind: .phoneHotspot,
                    title: "Hotspot",
                    detail: detail(
                        .phoneHotspot,
                        "This iPhone’s Personal Hotspot. Works anywhere you have cellular.",
                        "Best on the move"),
                    actionTitle: "Choose hotspot"),
            ],
            footer: context.camera == nil
                ? "Choose the shared network before adding cameras. Saved passwords stay on this iPhone."
                : "Camera Wi-Fi stays available. Switch setups from the camera’s chips at any time.",
            identifierPrefix: context.prefix)
    }

    /// A camera's own access point: the brand's prefix, this camera's, or another saved camera's.
    public static func isCameraNetwork(
        _ ssid: String, brand: StationNetworkBrand, camera: SavedCamera?, cameraSSIDs: Set<String>
    ) -> Bool {
        ssid.lowercased().hasPrefix(brand.cameraNetworkPrefix)
            || ssid == camera.flatMap { network($0, .cameraAccessPoint) }
            || cameraSSIDs.contains(ssid)
    }

    /// iOS hides this phone's name (its hotspot name) from apps, but the camera sees the
    /// hotspot. Phone-like names among the networks the camera found.
    public static func phoneNetworks(_ found: [String]) -> [String] {
        found.filter {
            let name = $0.lowercased()
            return name.contains("iphone") || name.contains("ipad")
        }
    }

    /// The network a camera's saved route of this kind uses.
    public static func network(_ camera: SavedCamera, _ kind: RouteKind) -> String? {
        camera.routes.first { $0.kind == kind }?.network
    }
}
