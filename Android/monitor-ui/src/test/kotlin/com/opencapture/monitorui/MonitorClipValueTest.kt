package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

class MonitorClipValueTest {
    @Test fun existingConstructorDefaultsCarryNoInventedMediaFacts() {
        val clip = MonitorClipValue("SIMULATED/01", "01.MOV", "4K · 24", "00:08", "PROXY", false)
        assertEquals("SIMULATED/01", clip.id)
        assertEquals("01.MOV", clip.title)
        assertEquals("4K · 24", clip.detail)
        assertEquals("00:08", clip.duration)
        assertEquals("PROXY", clip.source)
        assertFalse(clip.favorite)
        assertNull(clip.progress)
        assertNull(clip.burstCount)
        assertNull(clip.mediaBadge)
        assertNull(clip.completionBadge)
        assertNull(clip.transferCaption)
        assertNull(clip.favoriteLabel)
        assertNull(clip.accessibilityDescription)
        assertNull(clip.selectionEntryLabel)
        assertEquals(MonitorPalette.muted, clip.sourceTint)
    }

    @Test fun zeroProgressIsKnownAndAbsentSourceStaysAbsent() {
        val clip = MonitorClipValue("SIMULATED/01", "01.MOV", "", null, null, false, progress = 0f)
        assertEquals(0f, clip.progress)
        assertNull(clip.duration)
        assertNull(clip.source)
        val unknown = clip.copy(progress = null)
        assertNull(unknown.progress)
    }

    @Test fun suppliedMediaFactsCarryNoRepresentationInference() {
        val clip = MonitorClipValue("SIMULATED/01", "01.JPG", "", null, null, false,
            progress = 0f, burstCount = 4, mediaBadge = "RAW+J", completionBadge = "EXPORTED",
            transferCaption = "CACHING 0%")
        assertEquals(4, clip.burstCount)
        assertEquals("RAW+J", clip.mediaBadge)
        assertEquals("EXPORTED", clip.completionBadge)
        assertEquals("CACHING 0%", clip.transferCaption)
        assertNull(clip.source)
    }
}
