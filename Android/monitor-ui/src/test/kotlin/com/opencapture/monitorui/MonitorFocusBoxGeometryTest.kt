package com.opencapture.monitorui

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import kotlin.test.Test
import kotlin.test.assertEquals

/** Twin of the SwiftUI MonitorFocusBoxGeometryTests: same cases, same numbers. */
class MonitorFocusBoxGeometryTest {
    private fun mark(x: Float, y: Float, area: MonitorTrackingRect? = null) =
        MonitorFocusMark(Offset(x, y), Color.White, area = area)

    private fun assertFrame(left: Float, top: Float, right: Float, bottom: Float, mark: MonitorFocusMark) {
        val frame = MonitorTrackingGeometry.focusBoxFrame(mark, 400f, 200f)
        assertEquals(left, frame.left, 0.0001f)
        assertEquals(top, frame.top, 0.0001f)
        assertEquals(right, frame.right, 0.0001f)
        assertEquals(bottom, frame.bottom, 0.0001f)
    }

    @Test
    fun `the standard tap box is a square of the short side around the point`() {
        assertFrame(186f, 86f, 214f, 114f, mark(0.5f, 0.5f))
    }

    @Test
    fun `a camera-reported area draws at its own size and centre`() {
        assertFrame(100f, 50f, 300f, 100f, mark(0.9f, 0.9f, MonitorTrackingRect(0.25, 0.25, 0.5, 0.25)))
    }

    @Test
    fun `an empty reported area falls back to the standard tap box`() {
        assertFrame(186f, 86f, 214f, 114f, mark(0.5f, 0.5f, MonitorTrackingRect(0.25, 0.25, 0.0, 0.25)))
    }

    @Test
    fun `a reported area keeps its own corner up to the cap and the tap box keeps six`() {
        val cap = 7f
        val small = MonitorTrackingGeometry.focusBoxFrame(
            mark(0f, 0f, MonitorTrackingRect(0.0, 0.0, 0.25, 0.2)), 400f, 200f)
        assertEquals(4.8f, MonitorTrackingGeometry.focusCornerRadius(small, true, cap), 0.0001f)
        val large = MonitorTrackingGeometry.focusBoxFrame(
            mark(0f, 0f, MonitorTrackingRect(0.0, 0.0, 0.5, 1.0)), 400f, 200f)
        assertEquals(7f, MonitorTrackingGeometry.focusCornerRadius(large, true, cap), 0.0001f)
        val tap = MonitorTrackingGeometry.focusBoxFrame(mark(0.5f, 0.5f), 400f, 200f)
        assertEquals(6f, MonitorTrackingGeometry.focusCornerRadius(tap, false, cap), 0.0001f)
    }
}
