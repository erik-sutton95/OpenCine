package com.opencapture.monitorui

import org.junit.Assert.assertEquals
import org.junit.Test

class MonitorPlaybackPageGeometryTest {
    @Test fun defaultBoundsKeepOriginalPictureGeometry() {
        var zoom = MonitorPlaybackZoom().pinchChanged(2f, .5f, .5f, 200f, 100f)
            .endGesture(200f, 100f)
        zoom = zoom.panChanged(1000f, -1000f).endGesture(200f, 100f)
        assertEquals(100f, zoom.offsetX, 0f)
        assertEquals(-50f, zoom.offsetY, 0f)
    }
    @Test fun capturedCanvasAndPresentationScaleKeepDesqueezeBounds() {
        var zoom = MonitorPlaybackZoom().pinchChanged(2f, .5f, .5f, 400f, 300f)
            .endGesture(400f, 300f, 1.5f, .75f)
        zoom = zoom.panChanged(1000f, -1000f).endGesture(400f, 300f, 1.5f, .75f)
        assertEquals(400f, zoom.offsetX, 0f)
        assertEquals(-75f, zoom.offsetY, 0f)
        zoom = zoom.panChanged(25f, 20f).endGesture(400f, 300f)
        assertEquals(200f, zoom.offsetX, 0f)
        assertEquals(-55f, zoom.offsetY, 0f)
    }
    @Test fun reducedPresentationCannotInventPanExtentAndResetDropsCommittedOffset() {
        var zoom = MonitorPlaybackZoom().pinchChanged(2f, .5f, .5f, 400f, 300f)
            .panChanged(1000f, -1000f).endGesture(400f, 300f, .25f, 0f)
        assertEquals(0f, zoom.offsetX, 0f)
        assertEquals(0f, zoom.offsetY, 0f)
        zoom = zoom.reset().panChanged(30f, 20f)
        assertEquals(MonitorPlaybackZoom(), zoom)
    }
    @Test fun continuousPanBoundsConsumeEachSampleOnceAndReverseFromTheClampedEdge() {
        var zoom = MonitorPlaybackZoom().pinchChanged(2f, .5f, .5f, 400f, 300f).endGesture(400f, 300f)
        zoom = zoom.panChangedBounded(1000f, -1000f, 400f, 300f, 1.5f, .75f)
        assertEquals(400f, zoom.offsetX, 0f); assertEquals(-75f, zoom.offsetY, 0f)
        zoom = zoom.panChangedBounded(950f, -950f, 400f, 300f, 1.5f, .75f)
        assertEquals(350f, zoom.offsetX, 0f); assertEquals(-25f, zoom.offsetY, 0f)
        zoom = zoom.panChangedBounded(800f, -900f, 400f, 300f, 1.5f, .75f)
        assertEquals(200f, zoom.offsetX, 0f); assertEquals(25f, zoom.offsetY, 0f)
        zoom = zoom.panChangedBounded(0f, 0f, 400f, 300f, 1.5f, .75f)
        assertEquals(-400f, zoom.offsetX, 0f); assertEquals(75f, zoom.offsetY, 0f)
        zoom = zoom.endGesture(400f, 300f, 1.5f, .75f)
            .panChangedBounded(10f, -5f, 400f, 300f, 1.5f, .75f)
        assertEquals(-390f, zoom.offsetX, 0f); assertEquals(70f, zoom.offsetY, 0f)
        val legacy = MonitorPlaybackZoom().pinchChanged(2f, .5f, .5f, 400f, 300f)
            .endGesture(400f, 300f).panChanged(1000f, -1000f)
        assertEquals(1000f, legacy.offsetX, 0f); assertEquals(-1000f, legacy.offsetY, 0f)
    }
    @Test fun continuousPinchBoundsDoNotCommitMagnificationBeforeReturnToTheGestureOrigin() {
        var zoom = MonitorPlaybackZoom().pinchChangedBounded(4f, 1f, .5f, 200f, 100f, 100f, 50f)
        assertEquals(4f, zoom.scale, 0f); assertEquals(-150f, zoom.offsetX, 0f)
        zoom = zoom.pinchChangedBounded(2f, 1f, .5f, 200f, 100f, 100f, 50f)
        assertEquals(2f, zoom.scale, 0f); assertEquals(-25f, zoom.offsetX, 0f)
        zoom = zoom.pinchChangedBounded(1f, 1f, .5f, 200f, 100f, 100f, 50f)
        assertEquals(1f, zoom.scale, 0f); assertEquals(0f, zoom.offsetX, 0f)
        assertEquals(MonitorPlaybackZoom(), zoom.endGesture(100f, 50f))
    }

}
