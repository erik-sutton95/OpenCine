package com.opencapture.opencine.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Swift `StationRoutes`: the connect card's plan, added setups, the move marker and setup failures. */
class StationRoutesTest {
    private val ap = SavedRoute(key = "ap", kind = RouteKind.CAMERA_ACCESS_POINT, network = "CAM-1", bluetooth = true)
    private val camera = SavedCamera(id = "c", integration = IntegrationID("org.example"), advertisedName = "Cam", model = "M", routes = listOf(ap), preferredRoute = ap.id)

    @Test fun theConnectCardNamesWhereTheCameraIsGoing() {
        assertEquals(
            listOf("Connecting over Bluetooth", "Joining camera Wi-Fi", "Opening the video link", "Starting the picture"),
            StationRoutes.steps(null).map { it.title },
        )
        val wifi = SavedRoute(key = "wifi", kind = RouteKind.INFRASTRUCTURE_NETWORK, network = "Studio")
        assertEquals(
            listOf("Connecting over Bluetooth", "Moving the camera to Studio", "Finding the camera", "Starting the picture"),
            StationRoutes.steps(wifi).map { it.title },
        )
        assertEquals("Moving the camera to Hotspot", StationRoutes.steps(SavedRoute(key = "hotspot", kind = RouteKind.PHONE_HOTSPOT))[1].title)
    }

    @Test fun anAddedSetupBecomesAWiFiOrHotspotRoute() {
        val wifi = StationRoutes.route(RouteDraft(RouteKind.INFRASTRUCTURE_NETWORK, "Studio", "secret12"))!!
        assertTrue(wifi.key == "wifi" && wifi.network == "Studio" && wifi.bluetooth)
        assertEquals("hotspot", StationRoutes.route(RouteDraft(RouteKind.PHONE_HOTSPOT, "Rig"))?.key)
        assertNull(StationRoutes.route(RouteDraft(RouteKind.USB, "x")))
        assertNull(StationRoutes.route(RouteDraft(RouteKind.INFRASTRUCTURE_NETWORK)))
        val added = StationRoutes.adding(wifi, StationRoutes.adding(wifi.copy(id = ConnectionRouteID()), camera))
        assertEquals(listOf(ap, wifi), added.routes, "one route per key")
    }

    @Test fun aMoveIsRememberedBeforeItHappens() {
        val wifi = SavedRoute(key = "wifi", kind = RouteKind.INFRASTRUCTURE_NETWORK, network = "Studio")
        val withWifi = camera.copy(routes = listOf(ap, wifi))
        val stamped = StationRoutes.stamping(withWifi, RouteKind.INFRASTRUCTURE_NETWORK)
        assertEquals(wifi.id, stamped.preferredRoute)
        assertTrue(StationRoutes.mayBeInStationRole(stamped))
        val legacy = StationRoutes.stamping(camera, RouteKind.PHONE_HOTSPOT)
        assertNull(legacy.preferredRoute)
        assertEquals("phoneHotspot", legacy.extras["lastSetup"])
        assertTrue(StationRoutes.mayBeInStationRole(legacy))
        assertFalse(StationRoutes.mayBeInStationRole(camera))
        assertEquals(camera, StationRoutes.stamping(camera, RouteKind.CAMERA_ACCESS_POINT))
    }

    @Test fun aFailedSetupOffersEditingItAndTheCameraWiFi() {
        val wifi = SavedRoute(key = "wifi", kind = RouteKind.INFRASTRUCTURE_NETWORK, network = "Studio")
        val failure = ConnectionFailure(ConnectionFailure.Reason.Other, null, "Couldn’t connect over Camera Wi-Fi", "m", listOf(RecoveryAction.Retry), "c")
        val routed = StationRoutes.withRouteActions(failure, wifi, camera)
        assertEquals("Couldn’t connect over Studio", routed.title)
        assertEquals(listOf(RecoveryAction.EditRoute(wifi.id), RecoveryAction.Retry, RecoveryAction.UseRoute(ap.id)), routed.actions)
        assertEquals(failure, StationRoutes.withRouteActions(failure, ap, camera))
        assertEquals(failure, StationRoutes.withRouteActions(failure, null, camera))
    }
}
