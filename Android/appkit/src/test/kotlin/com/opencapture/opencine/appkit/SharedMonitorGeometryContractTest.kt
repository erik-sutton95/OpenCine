package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MonitorLayoutPolicy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Joined cases call the placement producer used by the actual common popup. */
class SharedMonitorGeometryContractTest {
    @Test fun portraitRecordingCategoriesUseStatusEdgeAndClearTheSystemRail() {
        for (aspect in listOf(16f / 9f, 9f / 16f, 1f)) {
            for (fill in listOf(false, true)) {
                val layout = MonitorLayoutPolicy.fieldMonitor(393f, 852f, safeTop = 59f,
                    safeBottom = 34f, sourceAspect = aspect, fill = fill)
                val panel = monitorOperatorCapturePlacement(layout, top = true, panelHeight = 190f,
                    safeTop = 59f, safeBottom = 34f)
                assertEquals(layout.status.maxY + 6f, panel.y)
                assertEquals(layout.system.y - 12f, panel.y + panel.maxHeight)
                assertEquals(365f, panel.width)
                assertEquals(196.5f, panel.x + panel.width / 2f)
                assertTrue(panel.y + panel.maxHeight < layout.record.y)
            }
        }
    }

    /** Landscape recording categories float under the one popup top margin. */
    @Test fun landscapeRecordingCategoriesKeepThePopupTopMarginAcrossCutoutRotation() {
        for ((leading, trailing) in listOf(62f to 0f, 0f to 62f)) {
            val layout = MonitorLayoutPolicy.fieldMonitor(874f, 402f, safeLeading = leading,
                safeTrailing = trailing, safeBottom = 21f)
            // A full-screen drawer owns its bottom content padding; the well stays at the edge.
            val panel = monitorOperatorCapturePlacement(layout, top = true, panelHeight = 190f,
                safeLeading = leading, safeTrailing = trailing, safeBottom = 0f)
            assertEquals(MonitorLayoutPolicy.popupTopMargin(0f), panel.y)
            assertEquals(402f, panel.y + panel.maxHeight)
            assertEquals(480f, panel.width)
            assertEquals(437f, panel.x + panel.width / 2f)
        }
    }

    @Test fun bottomCameraDrawerKeepsItsWellAcrossCropAndAbsentReadouts() {
        val reference = MonitorLayoutPolicy.fieldMonitor(393f, 852f, safeTop = 59f, safeBottom = 34f)
        val referencePanel = monitorOperatorCapturePlacement(reference, top = false, panelHeight = 190f,
            safeTop = 59f, safeBottom = 34f)
        for (aspect in listOf(16f / 9f, 9f / 16f)) {
            for (fill in listOf(false, true)) {
                for (showsValues in listOf(false, true)) {
                    val layout = MonitorLayoutPolicy.fieldMonitor(393f, 852f, safeTop = 59f,
                        safeBottom = 34f, sourceAspect = aspect, fill = fill, showsValues = showsValues)
                    val panel = monitorOperatorCapturePlacement(layout, top = false, panelHeight = 190f,
                        safeTop = 59f, safeBottom = 34f)
                    assertEquals(referencePanel, panel)
                    assertEquals(layout.system.y - 12f, panel.y + minOf(190f, panel.maxHeight))
                }
            }
        }
    }
}
