import Foundation
import OpenCineMedia
import Testing

@testable import OpenCineNikon

/// OPENZCINE-IOS-6/-7 (build 281): the Z gallery asks for every cell's RAW companion on each
/// render. A lookup that scans the whole library per cell turns one render of a full card into a
/// main-thread hang, so the policy answers it from an index built once.
@Suite struct NikonGalleryRawCompanionTests {
    private static func item(_ filename: String, storage: UInt32 = 11) -> NikonGallerySourceItem {
        NikonGallerySourceItem(
            id: MediaAssetID("cam/\(storage)/\(filename)"), legacyID: filename, namespace: "cam",
            filename: filename, captureDate: "20260727T120000", pixelWidth: 6048,
            pixelHeight: 4000, sourcePixelWidth: nil, storageID: storage, storageMembership: nil,
            handle: 1, favorite: false, rating: nil, localEligible: nil)
    }

    @Test func companionPairsAJpegWithTheFirstRawOfTheSameCardAndStem() {
        let items = [
            Self.item("DSC_0001.JPG"), Self.item("DSC_0001.NEF", storage: 22),
            Self.item("DSC_0001.NEF"), Self.item("DSC_0002.JPG"), Self.item("DSC_0002.MOV"),
        ]
        let policy = NikonAppleGalleryProjectionPolicy(items: items, now: Date(), calendar: .current)
        #expect(policy.rawCompanion(of: items[0].id) == items[2].id, "same card only")
        #expect(policy.rawCompanion(of: items[2].id) == nil, "a RAW has no companion")
        #expect(policy.rawCompanion(of: items[3].id) == nil)
        #expect(policy.rawCompanion(of: MediaAssetID("unknown")) == nil)
    }

    @Test func everyCellOfALargeCardResolvesItsCompanionWithoutRescanningTheLibrary() {
        var items: [NikonGallerySourceItem] = []
        for index in 0..<3_000 {
            let stem = String(format: "DSC_%05d", index)
            items.append(Self.item("\(stem).JPG"))
            if index.isMultiple(of: 2) { items.append(Self.item("\(stem).NEF")) }
        }
        let policy = NikonAppleGalleryProjectionPolicy(items: items, now: Date(), calendar: .current)
        let started = ContinuousClock.now
        let paired = items.filter { policy.rawCompanion(of: $0.id) != nil }.count
        let elapsed = ContinuousClock.now - started
        #expect(paired == 1_500)
        #expect(elapsed < .seconds(1), "\(elapsed) for \(items.count) lookups")
    }
}
