package com.opencapture.opencine.nikon

import com.opencapture.opencine.media.MediaAssetID
import com.opencapture.opencine.media.MonitorMediaProjection
import com.opencapture.opencine.media.MonitorMediaProjectionRequest
import com.opencapture.opencine.media.MonitorMediaProjectionSort
import java.time.LocalDate
import kotlin.test.Test
import kotlin.test.assertEquals

/** A4-15: Nikon galleries offer the shared RATING order (favorites first, then newest). */
class NikonGalleryRatingSortTest {
    private fun item(name: String, date: String, favorite: Boolean) = NikonGallerySourceItem(MediaAssetID(name), name, "bucket",
        NikonMediaClipRecord(handle = name.hashCode().toLong(), storageId = 1, sizeBytes = 4, captureDate = date,
            pixelWidth = 1_920, pixelHeight = 1_080, filename = "$name.MOV",
            contentKind = NikonMediaContentKind.PLAYABLE_PROXY, stillPhoto = null), favorite)

    @Test fun ratingOrdersFavoritesFirstThenNewest() {
        val items = listOf(item("old-fav", "20261001T100000", true), item("new", "20261003T100000", false),
            item("new-fav", "20261002T100000", true), item("old", "20261001T090000", false))
        val policy = NikonAndroidGalleryProjectionPolicy(items, LocalDate.of(2026, 10, 12))
        val result = MonitorMediaProjection.project(items.map { it.id },
            MonitorMediaProjectionRequest(sort = MonitorMediaProjectionSort.RATING), policy)
        assertEquals(listOf("new-fav", "old-fav", "new", "old"), result.displayIDs.map { it.rawValue })
    }
}
