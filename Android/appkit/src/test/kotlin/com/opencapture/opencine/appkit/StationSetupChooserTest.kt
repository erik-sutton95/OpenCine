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

    @Test fun hostRoutesJoinTheSharedChooserInOneOrderWithSharedCopy() {
        val chooser = stationSetupChooser(
            camera,
            routes = listOf(
                StationSetupRoute(RouteKind.USB, actionTitle = "Connect now"),
                StationSetupRoute(RouteKind.CAMERA_ACCESS_POINT, enabled = false),
                StationSetupRoute(RouteKind.PHONE_HOTSPOT),
                StationSetupRoute(RouteKind.INFRASTRUCTURE_NETWORK, actionTitle = "Find on this network"),
                StationSetupRoute(RouteKind.CAPTURE_DEVICE),
            ),
            notice = AddSetupNotice("names", "Allow names.", "Allow"),
        )
        assertEquals("How should this camera connect?", chooser.title)
        assertEquals("Body A · Model 1", chooser.detail)
        assertEquals(listOf("wifi", "phoneHotspot", "cameraAccessPoint", "usb", "captureDevice"), chooser.options.map { it.id })
        assertEquals(listOf("Wi-Fi", "Hotspot", "Camera Wi-Fi", "USB-C", "HDMI capture"), chooser.options.map { it.title })
        assertEquals(
            listOf("Find on this network", "Choose hotspot", "Choose camera Wi-Fi", "Connect now", "Choose HDMI capture"),
            chooser.options.map { it.actionTitle },
        )
        assertEquals(listOf(true, true, false, true, true), chooser.options.map { it.enabled })
        assertTrue(chooser.options[2].detail.startsWith("Added · BODY-AP\n"))
        assertEquals("names", chooser.notice?.id)
        // The camera's Wi-Fi is on offer, so the footer does not claim it is already there.
        assertEquals("Switch setups from the camera’s chips at any time.", chooser.footer)
        val words = listOf(chooser.title, chooser.detail, chooser.footer.orEmpty()) +
            chooser.options.flatMap { listOf(it.title, it.detail, it.actionTitle) }
        assertFalse(words.any { it.contains('\u2014') })
    }

    @Test fun aCameraWithoutModelIsNamedAlone() {
        assertEquals("Body A", stationSetupChooser(camera.copy(model = "")).detail)
    }

    @Test fun stationHostsKeepWiFiAndHotspotOnly() {
        val chooser = stationSetupChooser(camera)
        assertEquals(listOf("Choose Wi-Fi", "Choose hotspot"), chooser.options.map { it.actionTitle })
        assertEquals(null, chooser.notice)
        assertEquals("Camera Wi-Fi stays available. Switch setups from the camera’s chips at any time.", chooser.footer)
    }

    @Test fun multiviewChooserHasNoCamera() {
        val chooser = stationSetupChooser(null)
        assertEquals("How will your cameras connect?", chooser.title)
        assertEquals("", chooser.detail)
        assertTrue(chooser.footer.orEmpty().startsWith("Choose the shared network"))
    }
}
