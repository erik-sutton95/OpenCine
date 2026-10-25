package com.opencapture.monitorui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Swift twin: `MonitorInstantReviewLayoutTests` in MonitorPresentationTests. */
class MonitorInstantReviewLayoutTest {
    @Test fun wideStillLetterboxesInATallContainer() {
        assertEquals(MonitorRect(0f, 292f, 390f, 260f),
            MonitorInstantReviewLayout.imageFrame(6000f, 4000f, 390f, 844f))
    }

    @Test fun tallStillPillarboxesInALandscapeContainer() {
        assertEquals(MonitorRect(292f, 0f, 260f, 390f),
            MonitorInstantReviewLayout.imageFrame(4000f, 6000f, 844f, 390f))
    }

    @Test fun degenerateSizesDrawNothing() {
        assertEquals(MonitorRect(0f, 0f, 0f, 0f), MonitorInstantReviewLayout.imageFrame(0f, 10f, 100f, 100f))
        assertEquals(MonitorRect(0f, 0f, 0f, 0f), MonitorInstantReviewLayout.imageFrame(10f, 10f, 100f, 0f))
    }

    @Test fun closeSitsInTheTopTrailingCorner() {
        assertEquals(MonitorRect(796f, 14f, 34f, 34f), MonitorInstantReviewLayout.closeFrame(844f))
    }

    @Test fun favoriteStacksCentredOverTheSettingsLine() {
        assertEquals(MonitorRect(401f, 294f, 42f, 42f), MonitorInstantReviewLayout.favoriteFrame(844f, 390f, 30f))
        // Without the settings line the star drops to the bottom inset.
        assertEquals(MonitorRect(401f, 334f, 42f, 42f), MonitorInstantReviewLayout.favoriteFrame(844f, 390f, null))
    }

    @Test fun chromeMetricsMatchTheSwiftTwin() {
        assertEquals(34f, MonitorInstantReviewLayout.CLOSE_SIZE)
        assertEquals(14f, MonitorInstantReviewLayout.CLOSE_INSET)
        assertEquals(42f, MonitorInstantReviewLayout.FAVORITE_SIZE)
        assertEquals(19f, MonitorInstantReviewLayout.FAVORITE_GLYPH_SIZE)
        assertEquals(10f, MonitorInstantReviewLayout.STACK_SPACING)
        assertEquals(14f, MonitorInstantReviewLayout.BOTTOM_INSET)
        assertEquals(13f, MonitorInstantReviewLayout.INFO_FONT_SIZE)
        assertEquals(14f, MonitorInstantReviewLayout.STAND_IN_BLUR)
    }

    /** The review covers the whole monitor, so no chrome window may float above it. */
    @Test fun thePaletteNeverFloatsAboveAPresentedReview() {
        assertFalse(MonitorInstantReviewLayout.assistPaletteMayFloat(reviewPresented = true))
        assertTrue(MonitorInstantReviewLayout.assistPaletteMayFloat(reviewPresented = false))
    }

    /** Every chrome frame stays inside the review it belongs to, in both orientations. */
    @Test fun chromeStaysInsideTheReview() {
        for ((width, height) in listOf(390f to 844f, 844f to 390f, 1024f to 1366f)) {
            val review = MonitorRect(0f, 0f, width, height)
            for (frame in listOf(MonitorInstantReviewLayout.closeFrame(width),
                MonitorInstantReviewLayout.favoriteFrame(width, height, 30f))) {
                assertTrue("$frame inside $review", frame.minX >= 0f && frame.minY >= 0f &&
                    frame.maxX <= review.maxX && frame.maxY <= review.maxY)
            }
            assertFalse(MonitorInstantReviewLayout.closeFrame(width)
                .intersects(MonitorInstantReviewLayout.favoriteFrame(width, height, 30f)))
        }
    }
}
