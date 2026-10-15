package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.RouteKind
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** SIMULATED capabilities; selection dispatch never talks to a camera. */
class AddSetupChooserTest {
    @Test fun onlyEnabledAdvertisedCapabilitiesCanBeSelected() {
        val chooser = AddSetupChooser("Add a setup", "Choose a supported connection.", listOf(
            AddSetupOption("wifi", RouteKind.INFRASTRUCTURE_NETWORK, "Wi-Fi", "Same network", "Find"),
            AddSetupOption("usb", RouteKind.USB, "Cable", "Unavailable", "Connect", enabled = false),
        ))
        val selected = mutableListOf<RouteKind>()
        assertFalse(chooser.select("missing") { selected += it.kind })
        assertFalse(chooser.select("usb") { selected += it.kind })
        assertTrue(selected.isEmpty())
        assertTrue(chooser.select("wifi") { selected += it.kind })
        assertEquals(listOf(RouteKind.INFRASTRUCTURE_NETWORK), selected)
    }
}
