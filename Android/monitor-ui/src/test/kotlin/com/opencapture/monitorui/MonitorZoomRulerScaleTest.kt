package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Twin of `MonitorZoomRulerScaleTests.swift`. The ruler behaves like the other setting dials: the
 * scale slides under a fixed center line and a drag moves it relative to where it started.
 */
class MonitorZoomRulerScaleTest {
    private val major = MonitorZoomRulerTick.Kind.MAJOR
    private val mid = MonitorZoomRulerTick.Kind.MID

    @Test fun dragMovesSmoothlyFromTheOrigin() {
        val scale = MonitorZoomRulerScale(minimum = 1.0, maximum = 4.0)
        // The scale follows the finger: higher values sit above, so dragging down brings them in.
        assertEquals(2.0, scale.dragged(origin = 2.0, translation = 0.0))
        assertEquals(2.1, scale.dragged(origin = 2.0, translation = 10.0), 1e-9)
        assertEquals(1.75, scale.dragged(origin = 2.0, translation = -25.0), 1e-9)
        // Between ticks the zoom keeps float precision.
        assertEquals(2.04, scale.dragged(origin = 2.0, translation = 4.0), 1e-9)
    }

    @Test fun dragStopsAtTheEndsAndComesBack() {
        val scale = MonitorZoomRulerScale(minimum = 1.0, maximum = 4.0)
        assertEquals(4.0, scale.dragged(origin = 3.5, translation = 900.0))
        assertEquals(1.0, scale.dragged(origin = 1.2, translation = -900.0))
        assertEquals(2.637, scale.dragged(origin = 2.537, translation = 10.0), 1e-9)
    }

    @Test fun hapticStepsCountTenths() {
        assertEquals(20, MonitorZoomRulerScale.tick(2.0))
        assertEquals(20, MonitorZoomRulerScale.tick(2.09))
        assertEquals(21, MonitorZoomRulerScale.tick(2.1))
        assertEquals(9, MonitorZoomRulerScale.tick(0.3 * 3))
    }

    @Test fun offsetsAreRelativeToTheCenterLine() {
        val scale = MonitorZoomRulerScale(minimum = 1.0, maximum = 4.0)
        assertEquals(0.0, scale.offsetOf(2.0, center = 2.0))
        assertEquals(-50.0, scale.offsetOf(2.5, center = 2.0))
        assertEquals(50.0, scale.offsetOf(1.5, center = 2.0))
        assertEquals(2.5, scale.valueAtOffset(-50.0, center = 2.0))
        assertEquals(1.0, scale.valueAtOffset(999.0, center = 2.0))
    }

    @Test fun tapSnapsToANearbyWholeStep() {
        val scale = MonitorZoomRulerScale(minimum = 1.0, maximum = 4.0)
        assertEquals(3.0, scale.tapped(-95.0, center = 2.0)) // 2.95, 5 dp from the 3x label
        assertEquals(2.6, scale.tapped(-60.0, center = 2.0)) // far from a label: the tenth under the finger
    }

    @Test fun ticksCoverOnlyTheVisibleWindow() {
        val scale = MonitorZoomRulerScale(minimum = 1.0, maximum = 12.0)
        val ticks = scale.ticks(center = 6.0, halfSpan = 100.0) // 5.0 ... 7.0
        assertEquals(5.0, ticks.first().value)
        assertEquals(7.0, ticks.last().value)
        assertEquals(21, ticks.size)
        assertEquals(listOf(5.0, 6.0, 7.0), ticks.filter { it.kind == major }.map { it.value })
        assertEquals(listOf(5.5, 6.5), ticks.filter { it.kind == mid }.map { it.value })
        assertEquals(-50.0, ticks.first { it.value == 6.5 }.offset)
    }

    @Test fun ticksStopAtTheRange() {
        val scale = MonitorZoomRulerScale(minimum = 1.0, maximum = 2.35)
        val ticks = scale.ticks(center = 1.2, halfSpan = 300.0)
        assertEquals(1.0, ticks.first().value)
        assertEquals(2.3, ticks.last().value)
        assertEquals(2.35, scale.dragged(origin = 2.2, translation = 50.0))
        assertEquals(2.35, scale.clamped(9.0))
    }

    @Test fun noZoomRangeIsSafe() {
        val flat = MonitorZoomRulerScale(minimum = 1.0, maximum = 1.0)
        assertEquals(1.0, flat.dragged(origin = 1.0, translation = 40.0))
        assertEquals(listOf(1.0), flat.ticks(center = 1.0, halfSpan = 100.0).map { it.value })
        val broken = MonitorZoomRulerScale(minimum = 1.0, maximum = Double.NaN)
        assertEquals(1.0, broken.dragged(origin = Double.NaN, translation = Double.POSITIVE_INFINITY))
        assertTrue(broken.offsetOf(Double.NaN, center = 1.0).isFinite())
    }

    @Test fun readoutHasTwoDecimals() {
        assertEquals("2.50×", MonitorZoomRulerScale.readout(2.5))
        assertEquals("1.00×", MonitorZoomRulerScale.readout(1.0))
        assertEquals("2.53×", MonitorZoomRulerScale.readout(2.534))
    }
}
