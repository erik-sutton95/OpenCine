package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals

/** ZAB-524: the header says why Share waits on the camera cache, then returns to the clip facts. */
class MonitorPlaybackNoticeTest {
    @Test fun noticeReplacesTheFactsLineOnlyWhileItIsSet() {
        val facts = "3840x2160 · 25p · MOV"
        assertEquals(facts, MonitorPlaybackSourceValues().headerSubtitle(facts))
        assertEquals(facts, MonitorPlaybackSourceValues(notice = " ").headerSubtitle(facts))
        val caching = "Still caching from the camera. Share will finish the copy first."
        assertEquals(caching, MonitorPlaybackSourceValues(notice = caching).headerSubtitle(facts))
    }
}
