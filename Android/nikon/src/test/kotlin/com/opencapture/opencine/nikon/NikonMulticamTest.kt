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
        fun verdict(path: RouteKind?, reachable: Boolean = true, photo: Boolean = false) =
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
}
