package com.opencapture.opencine.media

import com.opencapture.opencine.core.StorageVolume
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MediaCatalogTest {
    private fun asset(id: String, volume: String) = MediaAsset(MediaAssetID(id), volume,
        "take.mov", MediaAssetKind.VIDEO, representations = emptyList())
    @Test fun proxyDeltaRemovesPreviouslyPublishedMaster() {
        val master = asset("master-content", "card"); val proxy = asset("proxy-content", "card")
        val first = MediaCatalog().applying(MediaCatalogDelta(upserts = listOf(master), complete = false))
        val next = first.applying(MediaCatalogDelta(upserts = listOf(proxy), removed = listOf(master.id), complete = true))
        assertEquals(listOf(master), first.assets)
        assertEquals(listOf(proxy), next.assets); assertTrue(next.complete)
    }
    @Test fun sameFilenameOnTwoVolumesStaysTwoAssets() {
        val a = asset("volume-a-content", "a"); val b = asset("volume-b-content", "b")
        val catalog = MediaCatalog().applying(MediaCatalogDelta(upserts = listOf(a, b),
            volumes = listOf(StorageVolume("a"), StorageVolume("b")), complete = true))
        assertEquals(a.filename, b.filename)
        assertEquals(listOf(a, b), catalog.assets); assertEquals(2, catalog.volumes?.size)
    }
    @Test fun recycledLocationOldRemovalCannotEraseNewContent() {
        val old = asset("retired-content", "a"); val current = asset("new-content", "a")
        val catalog = MediaCatalog().applying(MediaCatalogDelta(upserts = listOf(old), complete = false))
            .applying(MediaCatalogDelta(upserts = listOf(current), removed = listOf(old.id), complete = false))
            .applying(MediaCatalogDelta(removed = listOf(old.id), complete = true))
        assertEquals(old.filename, current.filename); assertEquals(old.volumeID, current.volumeID)
        assertEquals(listOf(current), catalog.assets)
    }
    @Test fun absentVolumeUpdatePreservesKnownFactsAndEmptyMeansKnownEmpty() {
        val known = MediaCatalog(volumes = listOf(StorageVolume("a")))
        assertEquals(known.volumes, known.applying(MediaCatalogDelta(reset = true, complete = true)).volumes)
        assertEquals(emptyList(), known.applying(MediaCatalogDelta(volumes = emptyList(), complete = true)).volumes)
    }
}
