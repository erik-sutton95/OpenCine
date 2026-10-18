package com.opencapture.opencine.cameracontrols

import kotlin.test.Test
import kotlin.test.assertEquals

/** Twin of the SwiftUI MonitorOperatorFocusInkTests: same cases. */
class MonitorOperatorFocusInkTest {
    @Test
    fun `AE lock wins over any focus result`() {
        assertEquals(MonitorOperatorFocusInk.AE_LOCK, MonitorOperatorFocusInk.of(aeLocked = true, focusConfirmed = true))
        assertEquals(MonitorOperatorFocusInk.AE_LOCK, MonitorOperatorFocusInk.of(aeLocked = true, focusConfirmed = null))
    }

    @Test
    fun `a camera focus result shows confirmed or unconfirmed`() {
        assertEquals(MonitorOperatorFocusInk.CONFIRMED, MonitorOperatorFocusInk.of(aeLocked = false, focusConfirmed = true))
        assertEquals(MonitorOperatorFocusInk.UNCONFIRMED, MonitorOperatorFocusInk.of(aeLocked = false, focusConfirmed = false))
    }

    @Test
    fun `without a camera focus result the tap box keeps the accent`() {
        assertEquals(MonitorOperatorFocusInk.ACCENT, MonitorOperatorFocusInk.of(aeLocked = false, focusConfirmed = null))
    }
}
