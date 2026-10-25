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

    /** Hardware pass 5.7: the heading names the state, never "No clips yet" over a filtered or offline card. */
    @Test fun titleNamesTheStateNotAnEmptyCard() {
        val copy = MediaLibraryCopy
        assertEquals(copy.LISTING_TITLE, copy.emptyTitle(listing = true, isLive = true, hasListedClips = false, activeFilterCount = 0))
        assertEquals(copy.FILTER_EMPTY_TITLE, copy.emptyTitle(listing = false, isLive = false, hasListedClips = true, activeFilterCount = 1))
        assertEquals(copy.FILTER_EMPTY_TITLE, copy.emptyTitle(listing = false, isLive = true, hasListedClips = true, activeFilterCount = 2))
        assertEquals(copy.DISCONNECTED_TITLE, copy.emptyTitle(listing = false, isLive = false, hasListedClips = false, activeFilterCount = 0))
        assertEquals(copy.NO_CACHED_TITLE, copy.emptyTitle(listing = false, isLive = false, hasListedClips = true, activeFilterCount = 0))
        assertEquals(copy.EMPTY_TITLE, copy.emptyTitle(listing = false, isLive = true, hasListedClips = false, activeFilterCount = 0))
    }

    /** Hardware pass 5.7: offline, the gallery lists only what this phone cached and says so. */
    @Test fun disconnectedGalleryHintSaysOnlyCachedClipsShow() {
        assertEquals(MediaLibraryCopy.DISCONNECTED_CACHED_ONLY, MediaLibraryCopy.galleryHint(fetching = false, selecting = false, isLive = false))
        assertEquals(MediaLibraryCopy.BROWSE_HINT, MediaLibraryCopy.galleryHint(fetching = false, selecting = false, isLive = true))
        assertEquals(MediaLibraryCopy.SELECTING_HINT, MediaLibraryCopy.galleryHint(fetching = false, selecting = true, isLive = false))
    }
}
