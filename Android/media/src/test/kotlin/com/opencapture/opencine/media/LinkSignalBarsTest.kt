package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals

/** Mirrors Swift `LinkSignalBarsTests`. */
class LinkSignalBarsTest {
    @Test fun quartileThresholdsMapToZeroToFourBarsFromAResetState() {
        for ((score, expected) in listOf(0 to 0, 1 to 1, 25 to 1, 26 to 2, 50 to 2, 51 to 3, 75 to 3, 76 to 4, 100 to 4)) {
            assertEquals(expected, LinkSignalBars().update(score), "score $score")
        }
    }

    @Test fun scoreHoveringAtABandBoundaryDoesNotFlicker() {
        val filter = LinkSignalBars()
        assertEquals(3, filter.update(74))
        assertEquals(3, filter.update(77))
        assertEquals(3, filter.update(74))
        assertEquals(3, filter.update(81))
        assertEquals(4, filter.update(82))
        assertEquals(4, filter.update(74))
        assertEquals(4, filter.update(70))
        assertEquals(3, filter.update(69))
    }

    @Test fun aMultiBandCollapseLandsOnTheRawBand() {
        val filter = LinkSignalBars()
        assertEquals(4, filter.update(95))
        assertEquals(2, filter.update(30))
    }

    @Test fun linkLossAndRecoveryBypassHysteresis() {
        val filter = LinkSignalBars()
        assertEquals(4, filter.update(90))
        assertEquals(0, filter.update(0))
        assertEquals(4, filter.update(85))
    }
}
