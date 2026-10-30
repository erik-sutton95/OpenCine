package com.opencapture.opencine.core

/**
 * The rules every integration follows when a setup moves a camera off its own access point onto a
 * shared network (a router's Wi-Fi or this phone's hotspot): the connect card's plan, the saved
 * route an added setup becomes, what the saved record remembers before the camera moves, and the
 * actions a failed setup offers. Copy lives here so every app reads the same. Swift twin:
 * `StationRoutes` in OpenCineCore.
 */
public object StationRoutes {
    /** Route kinds that move the camera onto a shared network. */
    public val MOVING: Set<RouteKind> = setOf(RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.PHONE_HOTSPOT)

    public fun moves(kind: RouteKind): Boolean = kind in MOVING

    /**
     * The connect card's plan over Bluetooth: camera Wi-Fi, or moving the camera to a Wi-Fi or
     * hotspot setup and finding it there.
     */
    public fun steps(route: SavedRoute?): List<ConnectionStep> {
        val moving = route != null && moves(route.kind)
        return listOf(
            ConnectionStep("Connecting over Bluetooth"),
            ConnectionStep(if (moving) "Moving the camera to ${name(route)}" else "Joining camera Wi-Fi"),
            ConnectionStep(if (moving) "Finding the camera" else "Opening the video link"),
            ConnectionStep("Starting the picture"),
        )
    }

    /**
     * The saved route a Wi-Fi or hotspot draft becomes (keys `wifi` and `hotspot`); `null` for any
     * other kind or a draft without a network.
     */
    public fun route(draft: RouteDraft): SavedRoute? {
        val network = draft.network?.takeIf { it.isNotEmpty() } ?: return null
        if (!moves(draft.kind)) return null
        return SavedRoute(
            key = if (draft.kind == RouteKind.PHONE_HOTSPOT) "hotspot" else "wifi", kind = draft.kind,
            title = draft.title, network = network, bluetooth = true,
        )
    }

    /** [camera] with [route] in place of any route of the same key. */
    public fun adding(route: SavedRoute, camera: SavedCamera): SavedCamera =
        camera.copy(routes = camera.routes.filter { it.key != route.key } + route)

    /**
     * [camera] remembering that a setup of [kind] may move it to station role: that route becomes
     * preferred, or without one the legacy `lastSetup` stays in `extras`. Camera Wi-Fi is stamped
     * only once live, so a failed restore is retried on the next connect.
     */
    public fun stamping(camera: SavedCamera, kind: RouteKind): SavedCamera {
        if (!moves(kind)) return camera
        val route = camera.routes.firstOrNull { it.kind == kind }
        return if (route != null) {
            camera.copy(preferredRoute = route.id, extras = camera.extras - "lastSetup")
        } else {
            camera.copy(
                preferredRoute = null,
                extras = camera.extras + ("lastSetup" to if (kind == RouteKind.PHONE_HOTSPOT) "phoneHotspot" else "wifi"),
            )
        }
    }

    /**
     * A setup that moved the camera may have left it in station role, so a camera Wi-Fi connect
     * asks it back onto its own access point first.
     */
    public fun mayBeInStationRole(camera: SavedCamera): Boolean {
        val preferred = camera.routes.firstOrNull { it.id == camera.preferredRoute }?.kind
        return (preferred != null && moves(preferred)) || camera.extras["lastSetup"] in setOf("wifi", "phoneHotspot")
    }

    /**
     * A failed Wi-Fi or hotspot setup is titled by its network and offers editing the setup,
     * retrying, and the camera's own Wi-Fi when the camera has it.
     */
    public fun withRouteActions(failure: ConnectionFailure, route: SavedRoute?, camera: SavedCamera?): ConnectionFailure {
        if (route == null || !moves(route.kind)) return failure
        val ap = camera?.routes?.firstOrNull { it.kind == RouteKind.CAMERA_ACCESS_POINT }
        val actions = failure.actions.filter { it != RecoveryAction.Retry } + RecoveryAction.EditRoute(route.id) +
            RecoveryAction.Retry + listOfNotNull(ap?.let { RecoveryAction.UseRoute(it.id) })
        return failure.copy(title = "Couldn’t connect over ${route.title ?: name(route)}", actions = actions)
    }

    private fun name(route: SavedRoute?): String =
        route?.network ?: if (route?.kind == RouteKind.PHONE_HOTSPOT) "Hotspot" else "Wi-Fi"
}
