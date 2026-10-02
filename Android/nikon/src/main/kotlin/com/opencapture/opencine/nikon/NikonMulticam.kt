package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.CameraDeviceID
import com.opencapture.opencine.core.MulticamQualification
import com.opencapture.opencine.core.MulticamQualificationRefusal
import com.opencapture.opencine.core.RouteKind

/** Why a saved member path cannot join, Swift `NikonMulticamRefusal`. */
public enum class NikonMulticamRefusal {
    ALREADY_MEMBER,
    CAMERA_ACCESS_POINT,
    HDMI_CAPTURE,
    PHOTOGRAPHY_MODE,
    NOT_REACHABLE,
}

/** The qualified saved-path policy, Swift `NikonMulticamPolicy`. */
public object NikonMulticamPolicy {
    /** The lasting body identity; null until a connect has stamped a serial. */
    public fun device(serialNumber: String?): CameraDeviceID? =
        serialNumber?.trim()?.takeIf { it.isNotEmpty() }?.let {
            CameraDeviceID.durable(it, NikonOpenCineSession.INTEGRATION)
        }

    /** USB, router and hotspot may mix. This never joins a network or sends a command. */
    public fun refusal(
        path: RouteKind?,
        reachable: Boolean,
        isPhotography: Boolean,
        device: CameraDeviceID?,
        members: Collection<CameraDeviceID>,
    ): NikonMulticamRefusal? = when {
        device != null && device in members -> NikonMulticamRefusal.ALREADY_MEMBER
        isPhotography -> NikonMulticamRefusal.PHOTOGRAPHY_MODE
        else -> pathRefusal(path, reachable)
    }

    /** Route eligibility is independent of a camera mode observation. */
    private fun pathRefusal(path: RouteKind?, reachable: Boolean): NikonMulticamRefusal? = when {
        path == RouteKind.CAMERA_ACCESS_POINT -> NikonMulticamRefusal.CAMERA_ACCESS_POINT
        path == RouteKind.CAPTURE_DEVICE -> NikonMulticamRefusal.HDMI_CAPTURE
        path == null || !reachable -> NikonMulticamRefusal.NOT_REACHABLE
        else -> null
    }

    /**
     * Qualification for opening a saved member path. A path qualified before connect still
     * rechecks body identity and camera-reported mode after connect; it asserts neither a
     * serial nor movie mode that the camera has not reported. An unknown photography observation
     * permits opening an eligible saved path only, never a movie record operation.
     */
    public fun qualification(
        path: RouteKind?,
        reachable: Boolean,
        isPhotography: Boolean?,
        device: CameraDeviceID?,
        members: Collection<CameraDeviceID>,
    ): MulticamQualification {
        val reason = when {
            device != null && device in members -> NikonMulticamRefusal.ALREADY_MEMBER
            isPhotography == true -> NikonMulticamRefusal.PHOTOGRAPHY_MODE
            else -> pathRefusal(path, reachable)
        }
        return when (reason) {
            null -> MulticamQualification.Qualified
            else -> MulticamQualification.Refused(when (reason) {
                NikonMulticamRefusal.ALREADY_MEMBER -> MulticamQualificationRefusal.ALREADY_MEMBER
                NikonMulticamRefusal.CAMERA_ACCESS_POINT -> MulticamQualificationRefusal.UNSUPPORTED_CONFIGURATION
                NikonMulticamRefusal.HDMI_CAPTURE, NikonMulticamRefusal.PHOTOGRAPHY_MODE ->
                    MulticamQualificationRefusal.OPERATION_UNAVAILABLE
                NikonMulticamRefusal.NOT_REACHABLE -> MulticamQualificationRefusal.NOT_REACHABLE
            })
        }
    }
}
