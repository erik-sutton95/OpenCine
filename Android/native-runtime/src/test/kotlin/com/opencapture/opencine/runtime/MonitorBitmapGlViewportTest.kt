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

    @Test fun mirrorAxesUseTheirExistingUniformSlotsWithoutChangingSourceOrEffectValues() {
        val original = bitmapVulkanUniforms(null, aspectFill = true, mirrored = false)
        assertEquals(40, original.size)
        assertEquals(0f, original[39])
        for (horizontal in listOf(false, true)) for (vertical in listOf(false, true)) {
            val transformed = bitmapVulkanUniforms(null, true, horizontal, vertical)
            assertEquals(if (horizontal) 1f else 0f, transformed[23])
            assertEquals(if (vertical) 1f else 0f, transformed[39])
            for (index in original.indices.filter { it != 23 && it != 39 }) {
                assertEquals(original[index], transformed[index], "Uniform $index must retain the source/effect value")
            }
        }
    }

}
