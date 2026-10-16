package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MultiviewToolAvailabilityTest {
    @Test fun explicitEmptyServicesNeverInferToolsFromOccupiedTiles() {
        val availability = MultiviewToolAvailability()
        assertEquals(listOf(MultiviewTool.LAYOUT, MultiviewTool.FIT), availability.offeredTools(
            listOf(MultiviewTool.CAMERA, MultiviewTool.LUT, MultiviewTool.LAYOUT, MultiviewTool.FIT), setOf(0, 1)))
        assertNull(availability.cameraSettingsSlot(0, setOf(0, 1)))
        assertNull(availability.pictureLUTSlot(0, setOf(0, 1)))
    }

    @Test fun commandOnlyAndRenderOnlyMembersOfferTheirActualServices() {
        val commands = MultiviewToolAvailability(cameraSettingsSlots = setOf(0))
        val rendering = MultiviewToolAvailability(pictureLUTSlots = setOf(1))
        assertEquals(listOf(MultiviewTool.LAYOUT, MultiviewTool.CAMERA, MultiviewTool.FIT), commands.offeredTools(
            listOf(MultiviewTool.LUT, MultiviewTool.LAYOUT, MultiviewTool.CAMERA, MultiviewTool.FIT), setOf(0)))
        assertEquals(listOf(MultiviewTool.FIT, MultiviewTool.LUT, MultiviewTool.LAYOUT), rendering.offeredTools(
            listOf(MultiviewTool.CAMERA, MultiviewTool.FIT, MultiviewTool.LUT, MultiviewTool.LAYOUT), setOf(1)))
    }

    @Test fun staleAndInvalidServiceSlotsCannotOfferAnAdapter() {
        val stale = MultiviewToolAvailability(cameraSettingsSlots = setOf(-1, 2, 99), pictureLUTSlots = setOf(2))
        assertEquals(listOf(MultiviewTool.LAYOUT, MultiviewTool.FIT), stale.offeredTools(
            listOf(MultiviewTool.CAMERA, MultiviewTool.LAYOUT, MultiviewTool.LUT, MultiviewTool.FIT), setOf(0, 1)))
        assertNull(stale.cameraSettingsSlot(2, setOf(0, 1)))
    }

    @Test fun mixedMembersSelectTheCurrentAdmittedSlotThenFirstValidFallback() {
        val availability = MultiviewToolAvailability(cameraSettingsSlots = setOf(1, 3), pictureLUTSlots = setOf(2))
        assertEquals(listOf(MultiviewTool.LUT, MultiviewTool.CAMERA, MultiviewTool.FIT, MultiviewTool.LAYOUT),
            availability.offeredTools(listOf(MultiviewTool.LUT, MultiviewTool.CAMERA, MultiviewTool.FIT, MultiviewTool.LAYOUT), setOf(0, 1, 2, 3)))
        assertEquals(3, availability.cameraSettingsSlot(3, setOf(0, 1, 2, 3)))
        assertEquals(1, availability.cameraSettingsSlot(0, setOf(0, 1, 2, 3)))
        assertEquals(1, availability.cameraSettingsSlot(3, setOf(0, 1, 2)))
        assertEquals(2, availability.pictureLUTSlot(0, setOf(0, 1, 2)))
    }
}
