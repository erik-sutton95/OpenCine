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

    // Owner request 2026-10-28: a zoomed clip fills the playback area instead of staying cropped
    // to its letterboxed 16:9 or 9:16 frame. Swift twin: MonitorPlaybackPageGeometryTests.
    @Test fun zoomedPictureCoversTheCanvasPastItsLetterboxAndOneTimesKeepsTheFrame() {
        val wide = MonitorRect(0f, 287.5f, 400f, 225f)
        assertEquals(wide, MonitorPlaybackZoom().visiblePictureRect(wide, 400f, 800f))
        var zoom = MonitorPlaybackZoom().pinchChanged(2f, .5f, .5f, 400f, 800f)
        assertEquals(MonitorRect(0f, 175f, 400f, 450f), zoom.visiblePictureRect(wide, 400f, 800f))
        zoom = zoom.pinchChanged(4f, .5f, .5f, 400f, 800f)
        assertEquals(MonitorRect(0f, 0f, 400f, 800f), zoom.visiblePictureRect(wide, 400f, 800f))

        val tall = MonitorRect(287.5f, 0f, 225f, 400f)
        assertEquals(tall, MonitorPlaybackZoom().visiblePictureRect(tall, 800f, 400f))
        val upright = MonitorPlaybackZoom().pinchChanged(2f, .5f, .5f, 800f, 400f)
        assertEquals(MonitorRect(175f, 0f, 450f, 400f), upright.visiblePictureRect(tall, 800f, 400f))
    }

    @Test fun zoomedPanStopsWhereThePictureMeetsTheCanvasEdgeNotTheLetterbox() {
        // 16:9 in portrait: at 2x the picture is narrower than the canvas is tall, so it stays
        // centred vertically; at 4x it overhangs the canvas by 50 px top and bottom.
        var zoom = MonitorPlaybackZoom().pinchChanged(2f, .5f, .5f, 400f, 800f)
            .panChanged(1000f, -1000f).endGesture(400f, 800f, pictureWidth = 400f, pictureHeight = 225f)
        assertEquals(200f, zoom.offsetX, 0f); assertEquals(0f, zoom.offsetY, 0f)
        zoom = zoom.pinchChanged(2f, .5f, .5f, 400f, 800f).panChanged(-3000f, 3000f)
            .endGesture(400f, 800f, pictureWidth = 400f, pictureHeight = 225f)
        assertEquals(4f, zoom.scale, 0f)
        assertEquals(-600f, zoom.offsetX, 0f); assertEquals(50f, zoom.offsetY, 0f)

        // 16:9 pillarboxed in landscape: the edge stops at the canvas (300), not at the
        // letterboxed frame (400), and the continuous path holds the same limit.
        var held = MonitorPlaybackZoom().pinchChangedBounded(2f, .5f, .5f, 1000f, 450f, 1000f, 450f,
            pictureWidth = 800f, pictureHeight = 450f)
        held = held.panChangedBounded(-2000f, 2000f, 1000f, 450f, pictureWidth = 800f, pictureHeight = 450f)
        assertEquals(-300f, held.offsetX, 0f); assertEquals(225f, held.offsetY, 0f)
        held = held.endPan(1000f, 450f, pictureWidth = 800f, pictureHeight = 450f)
            .endPinch(1000f, 450f, pictureWidth = 800f, pictureHeight = 450f)
        assertEquals(2f, held.scale, 0f)
        assertEquals(-300f, held.offsetX, 0f); assertEquals(225f, held.offsetY, 0f)
    }
}
