package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.MulticamQualification
import com.opencapture.opencine.core.MulticamQualificationRefusal
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedRoute

/**
 * Which saved Luna routes may join a multicam group (Swift `LunaMulticamPolicy`, same rules).
 * Several Lunas share one network only in station role: a router's Wi-Fi or this phone's hotspot.
 * The phone holds one camera access point at a time, so that route never joins. The member limit
 * is the app's `ResourceBudget`, not a Luna constant. This never joins a network or sends a
 * command.
 */
object LunaMulticamPolicy {
    /**
     * Qualification for opening [route] as a member next to [members]. [device] is the camera's
     * durable identity when known; null skips the member check (the connect still checks the
     * camera's serial).
     */
    fun qualification(route: SavedRoute?, device: CameraDeviceID?, members: Set<CameraDeviceID>): MulticamQualification {
        if (route == null) return MulticamQualification.Refused(MulticamQualificationRefusal.NOT_REACHABLE)
        return when (route.kind) {
            RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.PHONE_HOTSPOT ->
                if (device != null && device in members) MulticamQualification.Refused(MulticamQualificationRefusal.ALREADY_MEMBER)
                else MulticamQualification.Qualified
            RouteKind.CAMERA_ACCESS_POINT, RouteKind.USB, RouteKind.CAPTURE_DEVICE ->
                MulticamQualification.Refused(MulticamQualificationRefusal.UNSUPPORTED_CONFIGURATION)
        }
    }
}
