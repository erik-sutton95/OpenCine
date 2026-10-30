/// The rules every integration follows when a setup moves a camera off its own access point onto
/// a shared network (a router's Wi-Fi or this phone's hotspot): the connect card's plan, the saved
/// route an added setup becomes, what the saved record remembers before the camera moves, and the
/// actions a failed setup offers. Copy lives here so every app reads the same. Kotlin twin:
/// `StationRoutes` in `com.opencapture.opencine.core`.
public enum StationRoutes {
    /// Route kinds that move the camera onto a shared network.
    public static let moving: Set<RouteKind> = [.infrastructureNetwork, .phoneHotspot]

    public static func moves(_ kind: RouteKind) -> Bool { moving.contains(kind) }

    /// The connect card's plan over Bluetooth: camera Wi-Fi, or moving the camera to a Wi-Fi or
    /// hotspot setup and finding it there.
    public static func steps(_ route: SavedRoute?) -> [ConnectionStep] {
        let moving = route.map { moves($0.kind) } ?? false
        return [
            ConnectionStep(title: "Connecting over Bluetooth"),
            ConnectionStep(
                title: moving ? "Moving the camera to \(name(route))" : "Joining camera Wi-Fi"),
            ConnectionStep(title: moving ? "Finding the camera" : "Opening the video link"),
            ConnectionStep(title: "Starting the picture"),
        ]
    }

    /// The saved route a Wi-Fi or hotspot draft becomes (keys `wifi` and `hotspot`); nil for any
    /// other kind or a draft without a network.
    public static func route(adding draft: RouteDraft) -> SavedRoute? {
        guard moves(draft.kind), let network = draft.network, !network.isEmpty else { return nil }
        return SavedRoute(
            key: draft.kind == .phoneHotspot ? "hotspot" : "wifi", kind: draft.kind,
            title: draft.title, network: network, bluetooth: true)
    }

    /// `camera` with `route` in place of any route of the same key.
    public static func adding(_ route: SavedRoute, to camera: SavedCamera) -> SavedCamera {
        var camera = camera
        camera.routes.removeAll { $0.key == route.key }
        camera.routes.append(route)
        return camera
    }

    /// `camera` remembering that a setup of `kind` may move it to station role: that route
    /// becomes preferred, or without one the legacy `lastSetup` stays in `extras`. Camera Wi-Fi
    /// is stamped only once live, so a failed restore is retried on the next connect.
    public static func stamping(_ camera: SavedCamera, movingTo kind: RouteKind) -> SavedCamera {
        guard moves(kind) else { return camera }
        var camera = camera
        if let route = camera.routes.first(where: { $0.kind == kind }) {
            camera.preferredRoute = route.id
            camera.extras["lastSetup"] = nil
        } else {
            camera.preferredRoute = nil
            camera.extras["lastSetup"] = kind == .phoneHotspot ? "phoneHotspot" : "wifi"
        }
        return camera
    }

    /// A setup that moved the camera may have left it in station role, so a camera Wi-Fi connect
    /// asks it back onto its own access point first.
    public static func mayBeInStationRole(_ camera: SavedCamera) -> Bool {
        let preferred = camera.routes.first { $0.id == camera.preferredRoute }?.kind
        return preferred.map(moves) ?? false
            || ["wifi", "phoneHotspot"].contains(camera.extras["lastSetup"] ?? "")
    }

    /// A failed Wi-Fi or hotspot setup is titled by its network and offers editing the setup,
    /// retrying, and the camera's own Wi-Fi when the camera has it.
    public static func withRouteActions(
        _ failure: ConnectionFailure, route: SavedRoute?, camera: SavedCamera?
    ) -> ConnectionFailure {
        guard let route, moves(route.kind) else { return failure }
        var failure = failure
        failure.title = "Couldn’t connect over \(route.title ?? name(route))"
        let ap = camera?.routes.first { $0.kind == .cameraAccessPoint }
        failure.actions =
            failure.actions.filter { $0 != .retry } + [.editRoute(route.id), .retry]
            + (ap.map { [.useRoute($0.id)] } ?? [])
        return failure
    }

    private static func name(_ route: SavedRoute?) -> String {
        route?.network ?? (route?.kind == .phoneHotspot ? "Hotspot" : "Wi-Fi")
    }
}
