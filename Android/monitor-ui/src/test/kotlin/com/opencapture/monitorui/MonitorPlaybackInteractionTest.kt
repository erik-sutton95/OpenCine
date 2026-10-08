package com.opencapture.monitorui

import com.opencapture.opencine.media.MonitorPlaybackItemToken
import com.opencapture.opencine.media.MonitorPlaybackScrubToken
import java.util.UUID
import kotlin.test.*

class MonitorPlaybackInteractionTest {
    @Test fun cumulativePreviewDoesNotChangeItsOriginOrApplyPanTwice() {
        val origin = MonitorPlaybackZoom(maximumScale = 8f)
        val first = origin.preview(2f, 300f, 100f, 60f, 0f, 400f, 200f)
        val repeated = origin.preview(2f, 300f, 100f, 60f, 0f, 400f, 200f)
        assertEquals(first, repeated); assertEquals(1f, origin.scale); assertEquals(0f, origin.offsetX)
        assertEquals(2f, first.scale); assertEquals(-40f, first.offsetX); assertEquals(0f, first.offsetY)
    }
    @Test fun simultaneousPanIsAddedBeforeTheFinalPictureBounds() {
        val value = MonitorPlaybackZoom(maximumScale = 8f).preview(2f, -200f, 100f, -300f, 0f, 400f, 200f)
        assertEquals(100f, value.offsetX)
    }
    @Test fun inverseFocusUsesTheSamePreRotationPictureTransform() {
        val value = MonitorPlaybackZoom(maximumScale = 8f).preview(2f, 300f, 100f, 60f, -20f, 400f, 200f)
        val renderedX = 200f + (150f - 200f) * value.scale + value.offsetX
        val renderedY = 100f + (75f - 100f) * value.scale + value.offsetY
        assertEquals(150f to 75f, value.sourcePoint(renderedX, renderedY, 400f, 200f))
        assertEquals(-10f to 50f, MonitorPlaybackZoom().sourcePoint(-10f, 50f, 400f, 200f))
    }
    @Test fun incrementalTransformsRespectActualLetterboxedPictureBounds() {
        val value = MonitorPlaybackZoom(maximumScale = 8f).transformed(2f, 200f, 200f, 1000f, 1000f,
            400f, 400f, 400f, 200f)
        assertEquals(2f, value.scale); assertEquals(200f, value.offsetX); assertEquals(0f, value.offsetY)
        assertEquals(8f, value.maximumScale)
    }
    @Test fun settlingResetsNearOneButRetainsACommittedPictureOffset() {
        val origin = MonitorPlaybackZoom(maximumScale = 8f)
        val near = origin.transformed(1.04f, 200f, 100f, 0f, 0f, 400f, 200f).settled()
        assertEquals(1f, near.scale); assertEquals(8f, near.maximumScale)
        val held = origin.transformed(1.5f, 200f, 100f, 12f, 0f, 400f, 200f)
        assertEquals(held, held.settled())
    }
    @Test fun endingPinchDoesNotReplayAnActivePansCumulativeTranslation() {
        var zoom = MonitorPlaybackZoom().pinchChanged(2f, .5f, .5f, 400f, 200f)
        zoom = zoom.panChangedBounded(40f, 0f, 400f, 200f).endPinch(400f, 200f)
            .panChangedBounded(45f, 0f, 400f, 200f)
        assertEquals(45f, zoom.offsetX)
        zoom = zoom.endPan(400f, 200f).panChanged(5f, 0f)
        assertEquals(50f, zoom.offsetX)
    }
    @Test fun endingPanRetainsTheActivePinchsStartingScale() {
        var zoom = MonitorPlaybackZoom(maximumScale = 8f).pinchChanged(2f, .5f, .5f, 400f, 200f)
            .panChanged(20f, 0f).endPan(400f, 200f)
            .pinchChanged(3f, .5f, .5f, 400f, 200f)
        assertEquals(3f, zoom.scale); assertEquals(30f, zoom.offsetX)
        zoom = zoom.endPinch(400f, 200f).pinchChanged(4f, .5f, .5f, 400f, 200f)
        assertEquals(8f, zoom.scale); assertEquals(8f, zoom.reset().maximumScale)
    }
    @Test fun contextChangeRetiresBothOriginsWithoutChangingTheScaleLimit() {
        val zoom = MonitorPlaybackZoom(maximumScale = 8f).pinchChanged(2f, .5f, .5f, 400f, 200f)
            .panChanged(30f, 0f).endGesture(400f, 200f)
            .pinchChanged(2f, .5f, .5f, 400f, 200f).panChanged(5f, 0f)
        assertEquals(4f, zoom.scale); assertEquals(65f, zoom.offsetX)
    }
    @Test fun offCenterPinchKeepsSourceUnderFingerThenBoundsPanAndResets() {
        var zoom = MonitorPlaybackZoom().pinchChanged(2f, .75f, .5f, 200f, 100f)
        assertEquals(2f, zoom.scale)
        assertEquals(50f, 50f * zoom.scale + zoom.offsetX)
        zoom = zoom.endGesture(200f, 100f).panChanged(1000f, -1000f).endGesture(200f, 100f)
        assertEquals(100f, zoom.offsetX); assertEquals(-50f, zoom.offsetY)
        zoom = zoom.pinchChanged(.52f, .5f, .5f, 200f, 100f).endGesture(200f, 100f)
        assertEquals(1f, zoom.scale); assertEquals(0f, zoom.offsetX); assertEquals(0f, zoom.offsetY)
    }
    @Test fun verticalChromeSwipeKeepsDeadZoneAndRejectsDiagonalTravel() {
        assertEquals(MonitorPlaybackChromeSwipe.NONE, MonitorPlaybackChromeSwipe.classify(0f, 44f))
        assertEquals(MonitorPlaybackChromeSwipe.HIDE, MonitorPlaybackChromeSwipe.classify(0f, 45f))
        assertEquals(MonitorPlaybackChromeSwipe.SHOW, MonitorPlaybackChromeSwipe.classify(0f, -45f))
        assertEquals(MonitorPlaybackChromeSwipe.NONE, MonitorPlaybackChromeSwipe.classify(40f, 48f))
        assertEquals(MonitorPlaybackChromeSwipe.HIDE, MonitorPlaybackChromeSwipe.classify(40f, 49f))
    }
    @Test fun canceledSameItemEditCannotTakeItsSuccessorOrAdmitAnotherItem() {
        val item = MonitorPlaybackItemToken(UUID.randomUUID(), 1)
        val other = MonitorPlaybackItemToken(item.owner, 2)
        val a = MonitorPlaybackScrubToken(item); val b = MonitorPlaybackScrubToken(item)
        val editing = MonitorPlaybackEditing()
        assertTrue(editing.admit(a, item)); assertEquals(a, editing.take(a))
        assertTrue(editing.admit(b, item)); assertNull(editing.take(a))
        assertEquals(b, editing.token); assertEquals(b, editing.take(b))
        assertFalse(editing.admit(a, other))
    }
}
