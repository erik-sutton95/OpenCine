package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.media.MediaAssetID
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A rescan that prepends newer clips shows them first unless the operator scrolled away. */
class MonitorCatalogHeadAnchorTest {
    private val older = MediaAssetID("0163")
    private val newer = MediaAssetID("0168")

    @Test fun prependedClipsReturnARestingCatalogToTheTop() {
        val anchor = MonitorCatalogHeadAnchor()
        anchor.headChanged(older)
        // Keyed anchoring moves the first visible item without any scroll by the operator.
        anchor.scrolled(scrolling = false, atTop = false)
        assertTrue(anchor.headChanged(newer))
        assertFalse(anchor.headChanged(newer))
    }

    @Test fun anOperatorWhoScrolledAwayKeepsTheirPlace() {
        val anchor = MonitorCatalogHeadAnchor()
        anchor.headChanged(older)
        anchor.scrolled(scrolling = true, atTop = true)
        anchor.scrolled(scrolling = false, atTop = false)
        assertFalse(anchor.headChanged(newer))
        anchor.scrolled(scrolling = true, atTop = false)
        anchor.scrolled(scrolling = false, atTop = true)
        assertTrue(anchor.headChanged(older))
    }

    @Test fun aScrollInProgressIsNotInterrupted() {
        val anchor = MonitorCatalogHeadAnchor()
        anchor.headChanged(older)
        anchor.scrolled(scrolling = true, atTop = true)
        assertFalse(anchor.headChanged(newer))
    }
}
