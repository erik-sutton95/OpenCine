package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.MulticamQualification
import com.opencapture.opencine.core.MulticamQualificationRefusal
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedRoute
import kotlin.test.Test
import kotlin.test.assertEquals

/** Which saved Luna routes may join a multicam group. Swift twin: `LunaMulticamPolicyTests`, same test names. */
class LunaMulticamPolicyTest {
    private val camera = CameraDeviceID.durable("IAQEB2502ABCDE", LunaCameraSession.INTEGRATION)
    private val other = CameraDeviceID.durable("IAQEB2502FGHIJ", LunaCameraSession.INTEGRATION)

    private fun route(kind: RouteKind) = SavedRoute(key = kind.rawValue, kind = kind)
    private fun refused(reason: MulticamQualificationRefusal) = MulticamQualification.Refused(reason)

    @Test fun routerAndHotspotRoutesQualify() {
        for (kind in listOf(RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.PHONE_HOTSPOT)) {
            assertEquals(MulticamQualification.Qualified, LunaMulticamPolicy.qualification(route(kind), camera, setOf(other)))
            assertEquals(MulticamQualification.Qualified, LunaMulticamPolicy.qualification(route(kind), null, setOf(other)))
        }
    }

    @Test fun aCameraAlreadyInTheGroupIsRefused() {
        for (kind in listOf(RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.PHONE_HOTSPOT)) {
            assertEquals(
                refused(MulticamQualificationRefusal.ALREADY_MEMBER),
                LunaMulticamPolicy.qualification(route(kind), camera, setOf(camera, other)),
            )
        }
    }

    @Test fun theCameraAccessPointAndOtherRoutesAreRefused() {
        for (kind in listOf(RouteKind.CAMERA_ACCESS_POINT, RouteKind.USB, RouteKind.CAPTURE_DEVICE)) {
            assertEquals(
                refused(MulticamQualificationRefusal.UNSUPPORTED_CONFIGURATION),
                LunaMulticamPolicy.qualification(route(kind), camera, emptySet()),
            )
        }
    }

    @Test fun noSavedRouteIsNotReachable() {
        assertEquals(refused(MulticamQualificationRefusal.NOT_REACHABLE), LunaMulticamPolicy.qualification(null, camera, emptySet()))
    }
}
