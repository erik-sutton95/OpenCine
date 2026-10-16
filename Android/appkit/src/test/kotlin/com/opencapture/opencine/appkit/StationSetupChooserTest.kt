package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.RouteKind
import com.opencapture.opencine.core.SavedCamera
import com.opencapture.opencine.core.SavedRoute
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** SIMULATED saved camera; the station chooser never talks to a camera or a radio. */
class StationSetupChooserTest {
    private val camera = SavedCamera(
        id = "one", integration = IntegrationID("test.station"), advertisedName = "Body A", model = "Model 1",
        routes = listOf(
            SavedRoute(key = "ap", kind = RouteKind.CAMERA_ACCESS_POINT, network = "BODY-AP", bluetooth = true),
            SavedRoute(key = "wifi", kind = RouteKind.INFRASTRUCTURE_NETWORK, network = "studio", bluetooth = true),
        ),
    )

    @Test fun cameraChooserNamesTheCameraAndItsAddedSetups() {
        val chooser = stationSetupChooser(camera)
        assertEquals("How should this camera connect?", chooser.title)
        assertEquals("Body A · Model 1", chooser.detail)
        assertEquals("stationSetup", chooser.identifierPrefix)
        assertEquals(listOf("wifi", "phoneHotspot"), chooser.options.map { it.id })
        assertEquals(listOf(RouteKind.INFRASTRUCTURE_NETWORK, RouteKind.PHONE_HOTSPOT), chooser.options.map { it.kind })
        assertEquals(listOf("Wi-Fi", "Hotspot"), chooser.options.map { it.title })
        assertTrue(chooser.options[0].detail.startsWith("Added · studio\n"))
        assertFalse(chooser.options[1].detail.startsWith("Added"))
    }

    @Test fun multiviewChooserHasNoCamera() {
        val chooser = stationSetupChooser(null)
        assertEquals("How will your cameras connect?", chooser.title)
        assertEquals("", chooser.detail)
        assertTrue(chooser.footer.orEmpty().startsWith("Choose the shared network"))
    }
}
