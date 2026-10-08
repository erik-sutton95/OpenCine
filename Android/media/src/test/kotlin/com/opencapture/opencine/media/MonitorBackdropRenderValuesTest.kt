package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class MonitorBackdropRenderValuesTest {
    @Test fun boundsKeepOriginalCeilScaleAndCadence() {
        val scaled = assertNotNull(MonitorBackdropRenderValues.rasterSize(900.0, 600.0))
        assertEquals(320, scaled.width); assertEquals(214, scaled.height)
        assertEquals(320.0 / 900.0, scaled.scale)
        val small = assertNotNull(MonitorBackdropRenderValues.rasterSize(8.0, 8.0))
        assertEquals(MonitorBackdropRasterSize(8, 8, 1.0), small)
        assertEquals(1.0 / 60.0, MonitorBackdropRenderValues.MINIMUM_INTERVAL)
        assertEquals(16_666_667L, MonitorBackdropRenderValues.MINIMUM_INTERVAL_NS)
    }
    @Test fun invalidCanvasCannotInventARaster() {
        for (invalid in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, -1.0, 0.0, 1.0)) {
            assertNull(MonitorBackdropRenderValues.rasterSize(invalid, 20.0))
            assertNull(MonitorBackdropRenderValues.rasterSize(20.0, invalid))
        }
    }
    @Test fun sharedProductsKeepFirstOccurrenceOrder() {
        val compact = MonitorBackdropBlurProduct(18.0, 1.25)
        val expanded = MonitorBackdropBlurProduct(20.0, 1.25)
        val zoom = MonitorBackdropBlurProduct(24.0, 1.25)
        val scope = MonitorBackdropBlurProduct(8.0, 1.0)
        assertEquals(listOf(compact, expanded, zoom, scope), MonitorBackdropRenderValues.distinctProducts(
            listOf(compact, expanded, expanded, expanded, zoom, scope, compact)))
    }
    @Test fun unknownMapReadinessDiffersFromKnownClip() {
        assertNotEquals(MonitorBackdropLookState(220, null), MonitorBackdropLookState(220, 0))
        assertNotEquals(MonitorBackdropLookState(220, null), MonitorBackdropLookState(220, 220))
    }
}
