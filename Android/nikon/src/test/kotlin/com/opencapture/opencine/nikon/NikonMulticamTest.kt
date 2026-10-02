package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.MulticamQualification
import com.opencapture.opencine.core.MulticamQualificationRefusal
import com.opencapture.opencine.core.RouteKind
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class NikonMulticamTest {
    /** Swift `qualificationPreservesSavedPathPolicy`. */
    @Test
    fun qualificationPreservesSavedPathPolicy() {
        fun verdict(path: RouteKind?, reachable: Boolean = true, photo: Boolean? = null) =
            NikonMulticamPolicy.qualification(path, reachable, photo, device = null, members = emptyList())
        for (path in listOf(RouteKind.USB, RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.PHONE_HOTSPOT)) {
            assertEquals(MulticamQualification.Qualified, verdict(path))
        }
        fun refused(reason: MulticamQualificationRefusal) = MulticamQualification.Refused(reason)
        assertEquals(refused(MulticamQualificationRefusal.UNSUPPORTED_CONFIGURATION), verdict(RouteKind.CAMERA_ACCESS_POINT))
        assertEquals(refused(MulticamQualificationRefusal.OPERATION_UNAVAILABLE), verdict(RouteKind.CAPTURE_DEVICE))
        assertEquals(refused(MulticamQualificationRefusal.OPERATION_UNAVAILABLE), verdict(RouteKind.USB, photo = true))
        assertEquals(refused(MulticamQualificationRefusal.NOT_REACHABLE), verdict(RouteKind.USB, reachable = false))
        assertEquals(refused(MulticamQualificationRefusal.NOT_REACHABLE), verdict(null))
        val device = requireNotNull(NikonMulticamPolicy.device("test"))
        assertEquals(
            refused(MulticamQualificationRefusal.ALREADY_MEMBER),
            NikonMulticamPolicy.qualification(RouteKind.USB, true, false, device, listOf(device)))
        assertEquals(device, NikonMulticamPolicy.device(" test "))
        assertNull(NikonMulticamPolicy.device(null))
        assertNull(NikonMulticamPolicy.device("  "))
    }

    /** Swift `qualificationDoesNotInventUnknownCameraMode`. */
    @Test
    fun qualificationDoesNotInventUnknownCameraMode() {
        for (path in listOf(RouteKind.USB, RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.PHONE_HOTSPOT)) {
            fun verdict(photo: Boolean?) =
                NikonMulticamPolicy.qualification(path, true, photo, device = null, members = emptyList())
            // Unknown mode permits opening this saved path, without asserting movie eligibility.
            assertEquals(MulticamQualification.Qualified, verdict(null))
            assertEquals(MulticamQualification.Qualified, verdict(false))
            assertEquals(
                MulticamQualification.Refused(MulticamQualificationRefusal.OPERATION_UNAVAILABLE), verdict(true))
        }
        assertEquals(
            MulticamQualification.Refused(MulticamQualificationRefusal.UNSUPPORTED_CONFIGURATION),
            NikonMulticamPolicy.qualification(RouteKind.CAMERA_ACCESS_POINT, true, null, null, emptyList()))
        val device = requireNotNull(NikonMulticamPolicy.device("test"))
        assertEquals(
            MulticamQualification.Refused(MulticamQualificationRefusal.ALREADY_MEMBER),
            NikonMulticamPolicy.qualification(RouteKind.USB, true, null, device, listOf(device)))
    }
}
