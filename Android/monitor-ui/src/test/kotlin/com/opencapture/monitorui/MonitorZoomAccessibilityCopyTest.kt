package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals

class MonitorZoomAccessibilityCopyTest {
    @Test fun zoomStateDescribesTheCommittedScale() {
        assertEquals("Zoom 1.0x", monitorZoomStateDescription(1f))
        assertEquals("Zoom 2.5x", monitorZoomStateDescription(2.5f))
        assertEquals("Zoom 4.0x", monitorZoomStateDescription(4f))
    }
}
