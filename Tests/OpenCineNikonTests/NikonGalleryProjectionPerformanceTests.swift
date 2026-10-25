import Foundation
import OpenCineMedia
import Testing

@testable import OpenCineNikon

/// Z iOS 304 watchdog kill (2026-10-25, symbolicated): the gallery body projected every category
/// for its counts, and each projection ranked every still's L/M/S size by rebuilding and sorting
/// the width set per photo, O(photos^2). A 3200-object card (1500 RAW+JPEG pairs, 200 clips, three
/// still sizes) must project all four categories well inside one frame budget's order.
@Suite struct NikonGalleryProjectionPerformanceTests {
    private static func card() -> [NikonGallerySourceItem] {
        let widths: [UInt32] = [6048, 4528, 3024]
        var items: [NikonGallerySourceItem] = []
        for index in 0..<1500 {
            let stem = String(format: "DSC_%04d", index + 1)
            let day = 20 + index % 6
            for ext in ["NEF", "JPG"] {
                items.append(item("\(stem).\(ext)", width: widths[index % 3],
                    date: String(format: "202610%02dT%02d%02d00", day, (index / 60) % 24, index % 60),
                    handle: UInt32(items.count)))
            }
        }
        for index in 0..<200 {
            items.append(item(String(format: "DSC_%04d.MOV", 1501 + index), width: 3840,
                date: String(format: "20261019T%02d%02d30", index / 60, index % 60),
                handle: UInt32(items.count)))
        }
        return items
    }

    private static func item(_ filename: String, width: UInt32, date: String, handle: UInt32)
        -> NikonGallerySourceItem
    {
        NikonGallerySourceItem(
            id: MediaAssetID("cam/11/\(filename)"), legacyID: filename, namespace: "cam",
            filename: filename, captureDate: date, pixelWidth: width, pixelHeight: width * 2 / 3,
            sourcePixelWidth: nil, storageID: 11, storageMembership: [11], handle: handle,
            favorite: false, rating: nil, localEligible: nil)
    }

    @Test func projectingEveryCategoryOfALargeCardIsFast() {
        let items = Self.card()
        let now = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!
        let clock = ContinuousClock()
        let start = clock.now
        let policy = NikonAppleGalleryProjectionPolicy(items: items, now: now, calendar: .current)
        var counts: [Int] = []
        for category in [MonitorMediaProjectionCategory.all, .videos, .photos, .favorites] {
            let result = MonitorMediaProjection.project(
                items.map(\.id),
                request: .init(category: category, sort: .newest, formats: [], resolutions: [],
                    photoSizes: [], dateWindow: nil, storage: nil, requireLocal: false),
                policy: policy)
            counts.append(result.gridIDs.count)
        }
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        print("MEDIA-PERF nikon.project4categories.ms: \(String(format: "%.1f", ms)) counts \(counts)")
        #expect(counts[1] == 200, "every clip is a video")
        #expect(ms < 3000, "four projections took \(ms) ms")
    }

    /// The original per-still algorithm, kept here as the oracle.
    private static func reference(_ width: UInt32, _ present: [UInt32]) -> NikonMediaPhotoSizeClass? {
        guard width > 0 else { return nil }
        let ranked = Set(present.filter { $0 > 0 }).sorted(by: >)
        guard ranked.count <= NikonMediaPhotoSizeClass.allCases.count,
            let index = ranked.firstIndex(of: width) else { return nil }
        return NikonMediaPhotoSizeClass.allCases[index]
    }

    @Test func listingRankingMatchesPerStillRank() {
        for widths in [[6048, 4528, 3024], [6048, 6048], [8256, 5504, 4128, 3024], [0, 4000], []]
            .map({ $0.map(UInt32.init) })
        {
            let ranking = NikonMediaPhotoSizeClass.ranking(among: widths)
            for width in Set(widths + [1, 9999]) {
                #expect((width > 0 ? ranking[width] : nil) == Self.reference(width, widths))
                #expect(NikonMediaPhotoSizeClass.rank(pixelWidth: width, among: widths)
                    == Self.reference(width, widths))
            }
        }
    }
}
