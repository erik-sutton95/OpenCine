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
}
