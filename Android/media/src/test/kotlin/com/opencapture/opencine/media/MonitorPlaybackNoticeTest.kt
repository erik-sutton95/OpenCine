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

    /** A camera that does not share its files over this connection: the player's failure reads the
     * source's reason, and the reason never shows while the clip has not failed. */
    @Test fun unavailableReasonReplacesOnlyAPlayerFailure() {
        val generic = "Could not open that clip."
        val reason = "The camera is not sharing its files right now."
        assertEquals(generic, MonitorPlaybackSourceValues().loadError(generic))
        assertEquals(generic, MonitorPlaybackSourceValues(unavailableReason = " ").loadError(generic))
        assertEquals(reason, MonitorPlaybackSourceValues(unavailableReason = reason).loadError(generic))
        assertEquals(null, MonitorPlaybackSourceValues(unavailableReason = reason).loadError(null))
    }
}
