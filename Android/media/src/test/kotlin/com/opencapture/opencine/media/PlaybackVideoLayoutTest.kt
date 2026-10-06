package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PlaybackVideoLayoutTest {
    @Test
    fun aspectFitCentersTheRaster() {
        val rect =
            PlaybackVideoLayout.aspectFitRect(
                PlaybackVideoLayout.Size(16f, 9f),
                PlaybackVideoLayout.Rect(0f, 0f, 320f, 320f),
            )
        assertEquals(320f, rect.width, 0.01f)
        assertEquals(180f, rect.height, 0.01f)
        assertEquals(160f, rect.midY, 0.01f)
        assertEquals(0f, rect.minX, 0.01f)
        assertEquals(320f, rect.maxX, 0.01f)
    }

    @Test
    fun listedResolutionBecomesTheFeedRaster() {
        assertEquals(
            PlaybackVideoLayout.Size(3840f, 2160f),
            PlaybackVideoLayout.sizeFromResolution("3840x2160"),
        )
        assertEquals(
            PlaybackVideoLayout.Size(1080f, 1920f),
            PlaybackVideoLayout.sizeFromResolution("1080×1920"),
        )
        assertNull(PlaybackVideoLayout.sizeFromResolution(null))
        assertNull(PlaybackVideoLayout.sizeFromResolution("n/a"))
    }

    @Test
    fun letterboxedFeedIsSmallerThanTheScreen() {
        val screen = PlaybackVideoLayout.Rect(0f, 0f, 844f, 390f)
        val feed =
            PlaybackVideoLayout.aspectFitRect(
                PlaybackVideoLayout.Size(3840f, 2160f),
                screen,
            )
        assertTrue(feed.height <= screen.height + 0.01f)
        assertTrue(feed.width < screen.width - 1f)
        assertEquals(screen.midY, feed.midY, 0.01f)
        assertEquals(16f / 9f, feed.width / feed.height, 0.01f)
    }
}
