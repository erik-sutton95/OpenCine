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

/// One route the shared setup chooser offers, as data: its kind and, when the host knows better,
/// the live words of its action ("Connect now" once the camera is in reach). Copy for every kind
/// lives in the chooser so each app reads the same.
public struct StationSetupRoute: Equatable, Sendable {
    public var kind: RouteKind
    public var actionTitle: String?
    public var enabled: Bool

    public init(_ kind: RouteKind, actionTitle: String? = nil, enabled: Bool = true) {
        self.kind = kind
        self.actionTitle = actionTitle
        self.enabled = enabled
    }

    /// Wi-Fi and Hotspot: what a station-network host offers.
    public static let stationNetworks: [StationSetupRoute] = [
        .init(.infrastructureNetwork), .init(.phoneHotspot),
    ]
}

/// The station-network wizard's rules, apart from its view: chooser copy and which names count
/// as camera or phone networks.
public enum StationNetworkSetupRules {
    /// Shared copy for one route kind: option id, title, body, tag and default action.
    private static func copy(_ kind: RouteKind) -> (
        id: String, title: String, body: String, tag: String, action: String
    ) {
        switch kind {
        case .infrastructureNetwork:
            return (
                "wifi", "Wi-Fi",
                "A router, venue network or another device’s hotspot. Cameras and this iPhone join the same Wi-Fi.",
                "Best for studios and several cameras", "Choose Wi-Fi"
            )
        case .phoneHotspot:
            return (
                "phoneHotspot", "Hotspot",
                "This iPhone’s Personal Hotspot. Works anywhere you have cellular.",
                "Best on the move", "Choose hotspot"
            )
        case .cameraAccessPoint:
            return (
                "cameraAccessPoint", "Camera Wi-Fi",
                "This iPhone joins the camera’s own Wi-Fi. No router or hotspot needed.",
                "Best in the field with one camera", "Choose camera Wi-Fi"
            )
        case .usb:
            return (
                "usb", "USB-C",
                "Plug the camera straight into this iPhone. Nothing to set up.",
                "Best for a fixed rig", "Choose USB-C"
            )
        case .captureDevice:
            return (
                "captureDevice", "HDMI capture",
                "A USB HDMI capture device on this iPhone. Picture only, no camera control.",
                "Best when the camera has no network", "Choose HDMI capture"
            )
        }
    }

    /// The order every app lists its routes in: shared networks first, then the host's own.
    private static let order: [RouteKind] = [
        .infrastructureNetwork, .phoneHotspot, .cameraAccessPoint, .usb, .captureDevice,
    ]

    /// Host copy and supported station routes; the app keeps network and credential steps.
    /// `routes` are the kinds this host offers (Wi-Fi and Hotspot by default); a host adds its
    /// own, such as USB-C or the camera's Wi-Fi, as data and keeps what each one does.
    public static func setupChooser(
        context: StationNetworkSetupContext,
        routes: [StationSetupRoute] = StationSetupRoute.stationNetworks,
        notice: AddSetupNotice? = nil
    ) -> AddSetupChooser {
        func detail(_ kind: RouteKind, _ body: String, _ tag: String) -> String {
            [context.camera.flatMap { network($0, kind) }.map { "Added · \($0)" }, body, tag]
                .compactMap { $0 }.joined(separator: "\n")
        }
        let options = order.compactMap { kind -> AddSetupOption? in
            guard let route = routes.first(where: { $0.kind == kind }) else { return nil }
            let copy = copy(kind)
            return AddSetupOption(
                id: copy.id, kind: kind, title: copy.title,
                detail: detail(kind, copy.body, copy.tag),
                actionTitle: route.actionTitle ?? copy.action, enabled: route.enabled)
        }
        let footer: String
        if context.camera == nil {
            footer =
                "Choose the shared network before adding cameras. Saved passwords stay on this iPhone."
        } else if options.contains(where: { $0.kind == .cameraAccessPoint }) {
            footer = "Switch setups from the camera’s chips at any time."
        } else {
            footer =
                "Camera Wi-Fi stays available. Switch setups from the camera’s chips at any time."
        }
        return AddSetupChooser(
            title: context.camera == nil
                ? "How will your cameras connect?" : "How should this camera connect?",
            detail: context.camera.map {
                [$0.displayName, $0.model].filter { !$0.isEmpty }.joined(separator: " · ")
            } ?? "",
            options: options, footer: footer, identifierPrefix: context.prefix, notice: notice)
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
