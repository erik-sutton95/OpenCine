package com.opencapture.monitorui

import com.opencapture.opencine.media.MonitorPlaybackItemToken
import com.opencapture.opencine.media.MonitorPlaybackScrubToken
import java.util.UUID
import kotlin.test.*

class MonitorPlaybackInteractionTest {
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
