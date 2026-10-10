package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

class MonitorMediaDeliveryProjectLabelTest {
    @Test fun listedIDWinsOverSuppliedStaleLabel() {
        val service = MonitorMediaDeliveryValue.Service.Projects(
            heading = "PROJECT", help = "", loading = false,
            choices = listOf(MonitorMediaDeliveryValue.Choice("SIMULATED/1", "Listed project")),
            selectedID = "SIMULATED/1", selectedLabel = "Stale name",
        )
        assertEquals("Listed project", service.selectedProjectLabel)
    }

    @Test fun knownDestinationOutsideOfferedChoicesDoesNotInventAChoice() {
        val service = MonitorMediaDeliveryValue.Service.Projects(
            heading = "PROJECT", help = "", loading = false,
            choices = listOf(MonitorMediaDeliveryValue.Choice("SIMULATED/1", "Offered project")),
            selectedID = "SIMULATED/2", allowsCreation = false, selectedLabel = "Known destination",
        )
        assertEquals("Known destination", service.selectedProjectLabel)
        assertEquals(listOf("SIMULATED/1"), service.choices!!.map { it.id })
        assertFalse(service.allowsCreation)
    }

    @Test fun defaultAndUnavailableLabelsRemainAbsent() {
        val service = MonitorMediaDeliveryValue.Service.Projects(
            heading = "PROJECT", help = "", loading = false, choices = null, selectedID = null,
        )
        assertNull(service.selectedLabel)
        assertNull(service.selectedProjectLabel)
    }
}
