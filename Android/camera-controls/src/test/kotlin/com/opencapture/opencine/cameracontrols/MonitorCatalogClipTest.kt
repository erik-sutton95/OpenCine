package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.MonitorClipValue
import com.opencapture.opencine.appkit.MonitorMediaCacheAddress
import com.opencapture.opencine.appkit.MonitorMediaCacheEntry
import com.opencapture.opencine.appkit.MonitorMediaRecord
import com.opencapture.opencine.media.MediaAsset
import com.opencapture.opencine.media.MediaAssetID
import com.opencapture.opencine.media.MediaAssetKind
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** A4-17: a source cell (Nikon) keeps its own facts, the catalog owns cache state and progress. */
class MonitorCatalogClipTest {
    private val record = MonitorMediaRecord(MediaAsset(MediaAssetID("A"), filename = "DSC_0001.JPG", kind = MediaAssetKind.PHOTO, representations = emptyList()),
        "payload", MonitorMediaCacheAddress(null, emptyMap(), "A"), favorite = true)
    private val sourceCell = MonitorClipValue("source-id", "DSC_0001.JPG", "", null, "VIEW", false,
        mediaBadge = "24 MB", accessibilityDescription = "DSC_0001.JPG, view")
    private val facts = MonitorMediaGalleryFileFacts("JPG")
    private val file = File("unused")

    @Test fun sourceCellShowsTheCatalogCacheStateAndProgress() {
        val cached = monitorCatalogClip(record, MonitorMediaCacheEntry(file, null, null), facts, null, null, sourceCell)
        assertEquals("CACHED", cached.source)
        assertEquals("24 MB", cached.mediaBadge); assertEquals("DSC_0001.JPG, view", cached.accessibilityDescription)
        assertEquals("A", cached.id); assertEquals(true, cached.favorite)
        assertEquals("PROXY", monitorCatalogClip(record, MonitorMediaCacheEntry(null, file, null), facts, null, null, sourceCell).source)
        assertEquals("ON CAMERA", monitorCatalogClip(record, null, facts, null, null, sourceCell).source)
        val partial = monitorCatalogClip(record, null, facts.copy(progress = 0.25), null, 0.9, sourceCell)
        assertEquals(0.25f, partial.progress)
        assertEquals(0.5f, monitorCatalogClip(record, null, facts, null, 0.5, sourceCell).progress)
        assertNull(monitorCatalogClip(record, null, facts, null, null, sourceCell).progress)
    }

    @Test fun defaultCellKeepsItsFactsAndResolvedDuration() {
        val clip = monitorCatalogClip(record, MonitorMediaCacheEntry(file, null, null),
            facts.copy(duration = "00:04"), "00:05", null, null)
        assertEquals(MonitorClipValue("A", "DSC_0001.JPG", "JPG", "00:05", "CACHED", true, null), clip)
    }
}
