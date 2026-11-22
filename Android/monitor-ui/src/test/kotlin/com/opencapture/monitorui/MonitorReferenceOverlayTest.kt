package com.opencapture.monitorui

import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MonitorReferenceOverlayTest {
    @Test fun referenceUsesTheWholeApertureForFitAndTheSameCropForFill() {
        val well = Size(400f, 400f)
        assertEquals(Rect(0f, 100f, 400f, 300f), monitorReferenceRect(well, 2f, fill = false))
        assertEquals(Rect(-200f, 0f, 600f, 400f), monitorReferenceRect(well, 2f, fill = true))
        assertEquals(Rect(100f, 0f, 300f, 400f), monitorReferenceRect(well, 0.5f, fill = false))
    }

    @Test fun matchingAllowsRasterRoundingAndRejectsApertureChanges() {
        assertTrue(monitorReferenceMatches(16f / 9f, 854f / 480f))
        assertFalse(monitorReferenceMatches(16f / 9f, 4f / 3f))
        assertFalse(monitorReferenceMatches(16f / 9f, 9f / 16f))
        assertFalse(monitorReferenceMatches(16f / 9f, Float.NaN))
    }

    @Test fun swappingSplitSidesKeepsTheSameDividerAndClipsInsideTheVisiblePicture() {
        val visible = Rect(40f, 60f, 360f, 180f)
        assertEquals(Rect(40f, 60f, 140f, 180f), MonitorReferenceSide.LEFT.clip(visible, 140f))
        assertEquals(Rect(140f, 60f, 360f, 180f), MonitorReferenceSide.RIGHT.clip(visible, 140f))
        assertEquals(0f, MonitorReferenceSide.LEFT.clip(visible, visible.left).width)
        assertEquals(visible, MonitorReferenceSide.RIGHT.clip(visible, visible.left))
        assertEquals(visible, MonitorReferenceSide.LEFT.clip(visible, visible.right))
        assertEquals(0f, MonitorReferenceSide.RIGHT.clip(visible, visible.right).width)
    }

    @Test fun comparisonModesUseIndependentClampedRasterOpacities() {
        assertEquals(0.4f, MonitorReferenceMode.BLEND.rasterOpacity(blend = 0.4f, split = 0.8f))
        assertEquals(0.8f, MonitorReferenceMode.SPLIT.rasterOpacity(blend = 0.4f, split = 0.8f))
        assertEquals(0f, MonitorReferenceMode.SPLIT.rasterOpacity(blend = 0.4f, split = -0.1f))
        assertEquals(1f, MonitorReferenceMode.SPLIT.rasterOpacity(blend = 0.4f, split = 1.1f))
    }
}
