package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Twin of `MonitorZoomRulerScaleTests.swift`. */
class MonitorZoomRulerScaleTest {
    @Test fun endsMapToMinimumAndMaximum() {
        val scale = MonitorZoomRulerScale(minimum = 1.0, maximum = 4.0, length = 300.0)
        assertEquals(0.0, scale.offsetFor(4.0))
        assertEquals(300.0, scale.offsetFor(1.0))
        assertEquals(4.0, scale.valueAtOffset(-20.0))
        assertEquals(1.0, scale.valueAtOffset(999.0))
    }

    @Test fun dragRoundsToTenths() {
        // 10 dp per 0.1x.
        val scale = MonitorZoomRulerScale(minimum = 1.0, maximum = 4.0, length = 300.0)
        assertEquals(2.5, scale.valueAtOffset(150.0))
        assertEquals(2.5, scale.valueAtOffset(146.0))
        assertEquals(2.6, scale.valueAtOffset(144.0))
        assertEquals(2.5, scale.quantized(2.549_999))
        assertEquals(4.0, scale.quantized(9.0))
    }

    @Test fun tickKinds() {
        val ticks = MonitorZoomRulerScale(minimum = 1.0, maximum = 4.0, length = 300.0).ticks
        assertEquals(31, ticks.size)
        assertEquals(
            listOf(1.0, 2.0, 3.0, 4.0),
            ticks.filter { it.kind == MonitorZoomRulerTick.Kind.MAJOR }.map { it.value },
        )
        assertEquals(
            listOf(1.5, 2.5, 3.5),
            ticks.filter { it.kind == MonitorZoomRulerTick.Kind.MID }.map { it.value },
        )
        assertEquals(150.0, ticks.first { it.value == 2.5 }.offset)
    }

    @Test fun denseRangeDropsTenthTicks() {
        // 12x on a short landscape ruler: about 2.7 dp per 0.1x.
        val scale = MonitorZoomRulerScale(minimum = 1.0, maximum = 12.0, length = 300.0)
        assertFalse(scale.ticks.any { it.kind == MonitorZoomRulerTick.Kind.MINOR })
        assertEquals(11, scale.ticks.count { it.kind == MonitorZoomRulerTick.Kind.MID })
        assertEquals(12, scale.ticks.count { it.kind == MonitorZoomRulerTick.Kind.MAJOR })
        assertEquals(6.5, scale.valueAtOffset(150.0))
    }

    @Test fun noZoomRangeIsSafe() {
        val flat = MonitorZoomRulerScale(minimum = 1.0, maximum = 1.0, length = 300.0)
        assertEquals(1.0, flat.valueAtOffset(10.0))
        assertTrue(flat.offsetFor(1.0).isFinite())
        assertEquals(listOf(1.0), flat.ticks.map { it.value })
        val broken = MonitorZoomRulerScale(minimum = 1.0, maximum = Double.NaN, length = 300.0)
        assertEquals(1.0, broken.valueAtOffset(0.0))
        val empty = MonitorZoomRulerScale(minimum = 1.0, maximum = 4.0, length = 0.0)
        assertEquals(1.0, empty.valueAtOffset(0.0))
        assertTrue(empty.offsetFor(2.0).isFinite())
    }

    @Test fun fractionalMaximumKeepsItsTop() {
        val scale = MonitorZoomRulerScale(minimum = 1.0, maximum = 2.35, length = 270.0)
        assertEquals(2.35, scale.valueAtOffset(0.0))
        assertEquals(2.3, scale.ticks.last().value)
    }

    @Test fun readoutHasOneDecimal() {
        assertEquals("2.5×", MonitorZoomRulerScale.readout(2.5))
        assertEquals("1.0×", MonitorZoomRulerScale.readout(1.0))
        assertEquals("2.5×", MonitorZoomRulerScale.readout(2.549))
    }
}
