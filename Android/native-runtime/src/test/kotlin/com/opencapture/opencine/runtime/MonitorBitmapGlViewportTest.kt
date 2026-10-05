package com.opencapture.opencine.runtime

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MonitorBitmapGlViewportTest {
    @Test fun viewportMirrorsFitAndPortraitFillCanvasGeometry() {
        assertEquals(
            MonitorBitmapGlViewport(x = 0, y = 187, width = 400, height = 225),
            monitorBitmapGlViewport(400, 600, 1_920, 1_080, aspectFill = false),
        )
        assertEquals(
            MonitorBitmapGlViewport(x = -333, y = 0, width = 1_067, height = 600),
            monitorBitmapGlViewport(400, 600, 1_920, 1_080, aspectFill = true),
        )
        assertNull(monitorBitmapGlViewport(0, 600, 1_920, 1_080, aspectFill = true))
    }
}
