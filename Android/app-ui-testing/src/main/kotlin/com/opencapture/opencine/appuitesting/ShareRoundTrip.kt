package com.opencapture.opencine.appuitesting

import com.opencapture.monitorui.ReviewLaunch
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.junit.Test

/**
 * S2: the gallery and the player survive the share and delivery presentations: the selection share
 * leaves the gallery's position, selection and selection mode alone, and the clip share leaves the
 * same clip playing with Loop still on, then Back returns to the same gallery place. Never asserts a
 * delivery destination that depends on credentials, and never starts an export or the system sheet.
 */
@Conformance
public abstract class ShareRoundTrip(subject: ConformanceApp) : ConformanceTest(subject) {
    @Test
    public fun galleryAndPlayerSurviveShareAndDelivery() {
        launch(ReviewLaunch(ReviewLaunch.Screen.MEDIA))
        val gallery = MediaGalleryProbe(this)
        gallery.scrollTwoScreens()
        val visible = gallery.visibleClips()
        val anchor = gallery.settledAnchor()
        assertTrue(anchor != null && visible.size > 1, "Two visible clips are required")

        // Two clips selected by the shared sweep, then the selection share opened and closed.
        pressAndDrag(visible[0].bounds, visible[1].bounds)
        awaitLabel("2 selected", 5_000)
        tap(awaitLabel("Share selected clips", 5_000))
        val close = awaitTag(CLOSE, 5_000)
        checkpoint("selection-share")
        tap(close)
        assertTrue(awaitGone { it.tag == CLOSE }, "The selection share must close")
        assertEquals(anchor.id, gallery.settledAnchor()?.id, "The selection share must not move the gallery")
        assertNotNull(snapshot().nodes.firstOrNull { it.visible && it.label == "2 selected" },
            "The selection share must keep the selection")
        val clear = assertNotNull(snapshot().nodes.firstOrNull { it.visible && it.label == "Clear" && it.info.isClickable },
            "The selection share must keep selection mode")
        tap(clear)

        // The clip share from playback, with Loop on, then back to the gallery.
        val opened = assertNotNull(gallery.settledAnchor(), "No visible clip to open")
        tapAt(opened.bounds.centerX, opened.bounds.centerY)
        awaitTag(BACK, 10_000)
        val title = awaitTag(TITLE, 5_000).label
        val loop = awaitLabel(LOOP, 5_000)
        if (loop.state != "On") tap(loop)
        assertEquals("On", awaitLabel(LOOP).state, "Loop playback turns on")
        tap(awaitLabel("Share clip", 5_000))
        val destination = awaitTag(NATIVE_SHARE, 5_000)
        assertTrue(destination.enabled, "A cached staged clip can be shared")
        tap(destination)
        awaitTag("monitor.share.summary", 5_000)
        checkpoint("clip-share-summary")
        tap(awaitTag(CLOSE))
        assertTrue(awaitGone { it.tag == CLOSE }, "The clip share must close")
        assertEquals(title, awaitTag(TITLE).label, "Closing the share must keep the same clip")
        assertEquals("On", awaitLabel(LOOP).state, "Closing the share must keep the player's state")
        checkpoint("after-share")
        tap(awaitTag(BACK))
        assertTrue(awaitGone { it.tag == BACK }, "Back must close playback")
        assertEquals(opened.id, gallery.settledAnchor()?.id, "Back must return to the same gallery place")
    }

    private companion object {
        const val CLOSE = "monitor.share.close"
        const val BACK = "monitor.playback.back"
        const val TITLE = "monitor.playback.title"
        const val LOOP = "Loop clip"
        const val NATIVE_SHARE = "monitor.share.destination.NATIVE_SHARE"
    }
}
