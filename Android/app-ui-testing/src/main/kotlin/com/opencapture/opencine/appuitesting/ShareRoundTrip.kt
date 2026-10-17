package com.opencapture.opencine.appuitesting

import com.opencapture.monitorui.MonitorPlaybackCopy
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
        val (first, second) = assertNotNull(gallery.sweepPair(), "Two neighbouring clips wholly in view are required")

        // Two clips selected by the shared sweep, then the selection share opened and closed.
        pressAndDrag(first.bounds, second.bounds)
        awaitLabel("2 selected", 5_000)
        // Where the gallery rests once selected (a sweep near an edge may scroll it): the share must keep it.
        val anchor = assertNotNull(gallery.settledAnchor(), "No visible clip after the selection")
        tap(awaitLabel("Share selected clips", 5_000))
        val close = awaitTag(CLOSE, 5_000)
        checkpoint("selection-share")
        tap(close)
        assertTrue(awaitGone { it.tag == CLOSE }, "The selection share must close")
        assertEquals(anchor.id, gallery.settledAnchor()?.id, "The selection share must not move the gallery")
        assertNotNull(snapshot().nodes.firstOrNull { it.visible && it.label == "2 selected" },
            "The selection share must keep the selection")
        // The tray's Clear chip is announced by its description, as the Swift twin queries it.
        val clear = assertNotNull(snapshot().nodes.firstOrNull { it.visible && it.label == "Clear selection" && it.info.isClickable },
            "The selection share must keep selection mode")
        tap(clear)

        // The clip share from playback, with Loop on, then back to the gallery.
        val opened = assertNotNull(gallery.settledAnchor(), "No visible clip to open")
        tapAt(opened.bounds.centerX, opened.bounds.centerY)
        awaitTag(BACK, 10_000)
        val title = awaitTag(TITLE, 5_000).label
        val loop = awaitLabel(LOOP, 5_000)
        if (loop.state != MonitorPlaybackCopy.ON) tap(loop)
        // A player owner may publish the new state a beat after the tap.
        await("Loop playback turns on", 3_000) { it.label == LOOP && it.state == MonitorPlaybackCopy.ON }
        tap(awaitLabel(MonitorPlaybackCopy.SHARE, 5_000))
        val destination = awaitTag(NATIVE_SHARE, 5_000)
        assertTrue(destination.enabled, "A cached staged clip can be shared")
        tap(destination)
        // The destination opens its options; an app without export options shows no summary line.
        awaitTag("monitor.share.begin", 5_000)
        checkpoint("clip-share-summary")
        tap(awaitTag(CLOSE))
        assertTrue(awaitGone { it.tag == CLOSE }, "The clip share must close")
        assertEquals(title, awaitTag(TITLE).label, "Closing the share must keep the same clip")
        assertEquals(MonitorPlaybackCopy.ON, awaitLabel(LOOP).state, "Closing the share must keep the player's state")
        checkpoint("after-share")
        tap(awaitTag(BACK))
        assertTrue(awaitGone { it.tag == BACK }, "Back must close playback")
        assertEquals(opened.id, gallery.settledAnchor()?.id, "Back must return to the same gallery place")
    }

    private companion object {
        const val CLOSE = "monitor.share.close"
        const val BACK = "monitor.playback.back"
        const val TITLE = "monitor.playback.title"
        const val LOOP = MonitorPlaybackCopy.LOOP
        const val NATIVE_SHARE = "monitor.share.destination.NATIVE_SHARE"
    }
}
