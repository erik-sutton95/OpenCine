import MonitorPresentation
import Testing

struct MonitorClipValueTests {
    @Test func catalogStateAndExistingMetadataRemainGolden() {
        for (availability, source) in [
            (MonitorMediaItem.Availability.camera, "ON CAMERA"),
            (.proxy, "PROXY"), (.original, "ON PHONE"),
        ] {
            let item = MonitorMediaItem(
                id: "SIMULATED/01", filename: "01.MOV", metadata: "4K · 24",
                format: "MOV", color: "Log", duration: "00:08", availability: availability,
                favorite: true, photo: false)
            let cell = MonitorClipValue(item: item)
            #expect(cell.id == item.id)
            #expect(cell.title == "01.MOV")
            #expect(cell.detail == "4K · 24")
            #expect(cell.format == "MOV" && cell.color == "Log")
            #expect(cell.duration == "00:08" && cell.source == source)
            #expect(cell.favorite)
            #expect(cell.progress == nil && cell.transferCaption == nil)
            #expect(cell.burstCount == nil && cell.mediaBadge == nil && cell.completionBadge == nil)
            #expect(cell.favoriteLabel == nil && cell.accessibilityDescription == nil)
            #expect(cell.selectionEntryLabel == nil)
        }
    }

    @Test func zeroProgressIsKnownCachingAndAbsentSourceStaysAbsent() {
        let item = MonitorMediaItem(
            id: "SIMULATED/01", filename: "01.MOV", metadata: "", availability: .camera,
            progress: 0, favorite: false, photo: false)
        let cell = MonitorClipValue(item: item)
        #expect(cell.progress == 0 && cell.source == "CACHING")
        let unknown = MonitorClipValue(
            id: "SIMULATED/02", title: "02", detail: "", duration: nil, source: nil,
            favorite: false)
        #expect(unknown.duration == nil && unknown.source == nil && unknown.progress == nil)
    }

    @Test func suppliedMediaFactsCarryNoRepresentationInference() {
        let cell = MonitorClipValue(
            id: "SIMULATED/01", title: "01.JPG", detail: "", duration: nil, source: nil,
            favorite: false, progress: 0, burstCount: 4, mediaBadge: "RAW+J",
            completionBadge: "EXPORTED", transferCaption: "CACHING 0%")
        #expect(cell.burstCount == 4 && cell.mediaBadge == "RAW+J")
        #expect(cell.completionBadge == "EXPORTED" && cell.transferCaption == "CACHING 0%")
        #expect(cell.source == nil)
    }

    @Test func catalogItemCarriesSuppliedCameraBadgesToTheCell() {
        let item = MonitorMediaItem(
            id: "SIMULATED/01", filename: "01.JPG", metadata: "", availability: .camera,
            progress: 0.5, favorite: false, photo: true, burstCount: 4, mediaBadge: "RAW+J",
            completionBadge: "EXPORTED", transferCaption: "CACHING 50%")
        let cell = MonitorClipValue(item: item)
        #expect(cell.burstCount == 4 && cell.mediaBadge == "RAW+J")
        #expect(cell.completionBadge == "EXPORTED" && cell.transferCaption == "CACHING 50%")
        #expect(cell.progress == 0.5 && cell.source == "CACHING")
    }
}
