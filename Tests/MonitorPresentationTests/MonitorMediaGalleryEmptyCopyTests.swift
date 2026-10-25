import MonitorPresentation
import Testing

/// ZIB-413: an empty gallery names the filters before it blames the camera link or the cache.
/// Same table as Kotlin `MediaLibraryEmptyCopyTest`.
struct MonitorMediaGalleryEmptyCopyTests {
    @Test func offlineFilteredGalleryNamesTheFiltersNotTheCache() {
        #expect(MonitorMediaGalleryCopy.emptySubtitle(sourceAvailable: false, hasRecords: true, activeFilterCount: 1,
            tab: MonitorMediaGalleryCopy.emptyAll) == MonitorMediaGalleryCopy.filterEmpty)
        #expect(MonitorMediaGalleryCopy.emptySubtitle(sourceAvailable: true, hasRecords: true, activeFilterCount: 2,
            tab: MonitorMediaGalleryCopy.emptyVideos) == MonitorMediaGalleryCopy.filterEmpty)
    }
    @Test func offlineWithoutFiltersKeepsTheLinkAndCacheCopy() {
        #expect(MonitorMediaGalleryCopy.emptySubtitle(sourceAvailable: false, hasRecords: false, activeFilterCount: 0,
            tab: MonitorMediaGalleryCopy.emptyAll) == MonitorMediaGalleryCopy.disconnected)
        #expect(MonitorMediaGalleryCopy.emptySubtitle(sourceAvailable: false, hasRecords: true, activeFilterCount: 0,
            tab: MonitorMediaGalleryCopy.emptyPhotos) == MonitorMediaGalleryCopy.disconnectedEmptyCache)
        #expect(MonitorMediaGalleryCopy.emptySubtitle(sourceAvailable: true, hasRecords: true, activeFilterCount: 0,
            tab: MonitorMediaGalleryCopy.emptyPhotos) == MonitorMediaGalleryCopy.emptyPhotos)
    }
    /// Hardware pass 5.7: "No clips yet" headed a gallery whose clips were filtered out, or whose
    /// camera was disconnected with clips on its card.
    @Test func titleNamesTheStateNotAnEmptyCard() {
        typealias Copy = MonitorMediaGalleryCopy
        #expect(Copy.emptyTitle(fetching: true, sourceAvailable: true, hasRecords: false, activeFilterCount: 0) == Copy.listingTitle)
        #expect(Copy.emptyTitle(fetching: false, sourceAvailable: false, hasRecords: true, activeFilterCount: 1) == Copy.filterEmptyTitle)
        #expect(Copy.emptyTitle(fetching: false, sourceAvailable: true, hasRecords: true, activeFilterCount: 2) == Copy.filterEmptyTitle)
        #expect(Copy.emptyTitle(fetching: false, sourceAvailable: false, hasRecords: false, activeFilterCount: 0) == Copy.disconnectedTitle)
        #expect(Copy.emptyTitle(fetching: false, sourceAvailable: false, hasRecords: true, activeFilterCount: 0) == Copy.noCachedTitle)
        #expect(Copy.emptyTitle(fetching: false, sourceAvailable: true, hasRecords: false, activeFilterCount: 0) == Copy.emptyTitle)
        for title in [Copy.listingTitle, Copy.filterEmptyTitle, Copy.disconnectedTitle, Copy.noCachedTitle] {
            #expect(title != Copy.emptyTitle)
        }
    }
    /// Hardware pass 5.7: offline, the gallery lists only what this phone cached and says so.
    @Test func disconnectedGalleryHintSaysOnlyCachedClipsShow() {
        #expect(MonitorMediaGalleryCopy.galleryHint(sourceAvailable: false, selecting: false)
            == MonitorMediaGalleryCopy.disconnectedCachedOnly)
        #expect(MonitorMediaGalleryCopy.disconnectedCachedOnly.contains("disconnected"))
        #expect(MonitorMediaGalleryCopy.galleryHint(sourceAvailable: true, selecting: false) == MonitorMediaGalleryCopy.browseHint)
        #expect(MonitorMediaGalleryCopy.galleryHint(sourceAvailable: false, selecting: true) == MonitorMediaGalleryCopy.selectingHint)
    }
}
