package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.MediaLibraryTab
import org.junit.Assert.assertEquals
import org.junit.Test

/** ZIB-413: an empty gallery names the filters before it blames the camera link or the cache. */
class MediaLibraryEmptyCopyTest {
    @Test fun offlineFilteredGalleryNamesTheFiltersNotTheCache() {
        assertEquals(MediaLibraryCopy.FILTER_EMPTY,
            MediaLibraryCopy.emptySubtitle(isLive = false, hasListedClips = true, activeFilterCount = 1, category = MediaLibraryTab.ALL))
        assertEquals(MediaLibraryCopy.FILTER_EMPTY,
            MediaLibraryCopy.emptySubtitle(isLive = true, hasListedClips = true, activeFilterCount = 2, category = MediaLibraryTab.VIDEOS))
    }

    @Test fun offlineWithoutFiltersKeepsTheLinkAndCacheCopy() {
        assertEquals(MediaLibraryCopy.DISCONNECTED,
            MediaLibraryCopy.emptySubtitle(isLive = false, hasListedClips = false, activeFilterCount = 0, category = MediaLibraryTab.ALL))
        assertEquals(MediaLibraryCopy.DISCONNECTED_EMPTY_CACHE,
            MediaLibraryCopy.emptySubtitle(isLive = false, hasListedClips = true, activeFilterCount = 0, category = MediaLibraryTab.PHOTOS))
    }
}
