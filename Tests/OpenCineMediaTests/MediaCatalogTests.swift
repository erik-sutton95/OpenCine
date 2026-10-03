import OpenCineCore
import OpenCineMedia
import Testing

@Suite struct MediaCatalogTests {
    private func asset(_ id: String, volume: String, filename: String = "take.mov") -> MediaAsset {
        .init(id: .init(id), volumeID: volume, filename: filename, kind: .video, representations: [])
    }
    @Test func proxyDeltaRemovesPreviouslyPublishedMaster() {
        let master = asset("master-content", volume: "card")
        let proxy = asset("proxy-content", volume: "card")
        let first = MediaCatalog().applying(.init(upserts: [master], complete: false))
        let next = first.applying(.init(upserts: [proxy], removed: [master.id], complete: true))
        #expect(first.assets == [master])
        #expect(next.assets == [proxy] && next.complete)
    }
    @Test func sameFilenameOnTwoVolumesStaysTwoAssets() {
        let a = asset("volume-a-content", volume: "a"), b = asset("volume-b-content", volume: "b")
        let catalog = MediaCatalog().applying(.init(upserts: [a, b],
            volumes: [.init(id: "a"), .init(id: "b")], complete: true))
        #expect(a.filename == b.filename)
        #expect(catalog.assets == [a, b] && catalog.volumes?.count == 2)
    }
    @Test func recycledLocationOldRemovalCannotEraseNewContent() {
        let old = asset("retired-content", volume: "a"), current = asset("new-content", volume: "a")
        let catalog = MediaCatalog().applying(.init(upserts: [old], complete: false))
            .applying(.init(upserts: [current], removed: [old.id], complete: false))
            .applying(.init(removed: [old.id], complete: true))
        #expect(old.filename == current.filename && old.volumeID == current.volumeID)
        #expect(catalog.assets == [current])
    }
    @Test func absentVolumeUpdatePreservesKnownFactsAndEmptyMeansKnownEmpty() {
        let known = MediaCatalog(volumes: [.init(id: "a")])
        #expect(known.applying(.init(reset: true, complete: true)).volumes == known.volumes)
        #expect(known.applying(.init(volumes: [], complete: true)).volumes == [])
    }
}
