package com.opencapture.opencine.appuitesting

import com.opencapture.monitorui.MonitorMediaLayout
import com.opencapture.monitorui.ReviewLaunch
import kotlin.math.abs
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.junit.Test

/**
 * S1: the gallery is where the operator left it after playback opens and closes: same clip at the
 * same place, same layout and category, in both orientations and both layouts. A presentation that
 * gives the gallery a new identity (a modifier toggled by playback) fails here.
 */
@Conformance
public abstract class GalleryRoundTrip(subject: ConformanceApp) : ConformanceTest(subject) {
    @Test
    public fun gridGalleryReturnsFromPlaybackWhereItWas(): Unit = roundTrip(MonitorMediaLayout.GRID)

    @Test
    public fun listGalleryReturnsFromPlaybackWhereItWas(): Unit = roundTrip(MonitorMediaLayout.LIST)

    private fun roundTrip(layout: MonitorMediaLayout) {
        launch(ReviewLaunch(ReviewLaunch.Screen.MEDIA, layout = layout))
        val gallery = MediaGalleryProbe(this)
        awaitTag(MediaGalleryProbe.GALLERY)
        for (landscape in listOf(false, true)) {
            rotate(landscape) { node(MediaGalleryProbe.GALLERY) }
            gallery.scrollTwoScreens()
            val anchor = assertNotNull(gallery.settledAnchor(), "No visible clip to return to")
            val layoutBefore = gallery.selected("layout")
            val categoryBefore = gallery.selected("category")
            assertEquals("monitor.media.layout.${layout.name.lowercase()}", layoutBefore)
            tapAt(anchor.bounds.centerX, anchor.bounds.centerY)
            val back = awaitTag(BACK, 10_000)
            checkpoint("playback")
            tap(back)
            assertTrue(awaitGone { it.tag == BACK }, "Back must close playback")
            val returned = gallery.settledAnchor()
            assertEquals(anchor.id, returned?.id, "The gallery must return to the clip it opened")
            val moved = abs((returned?.bounds?.top ?: Int.MIN_VALUE) - anchor.bounds.top)
            assertTrue(moved <= density + 1, "The clip must return to the same place (moved $moved px)")
            assertEquals(layoutBefore, gallery.selected("layout"))
            assertEquals(categoryBefore, gallery.selected("category"))
            checkpoint("after-return")
        }
    }

    private companion object {
        const val BACK = "monitor.playback.back"
    }
}
