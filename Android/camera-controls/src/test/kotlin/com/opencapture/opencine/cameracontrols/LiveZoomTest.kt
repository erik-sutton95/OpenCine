package com.opencapture.opencine.cameracontrols

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LiveZoomTest {
    @Test
    fun labelHoldIgnoresSubTenthJitterUnlessPinching() {
        assertFalse(LiveZoomLabelHold.shouldReplace(held = 2.0, next = 2.08, pinching = false))
        assertTrue(LiveZoomLabelHold.shouldReplace(held = 2.0, next = 2.08, pinching = true))
        assertTrue(LiveZoomLabelHold.shouldReplace(held = 2.0, next = 2.2, pinching = false))
    }
}
