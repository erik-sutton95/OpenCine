import Foundation
import Testing

@testable import OpenCineNikon

@Suite("Instant review: object choice")
struct NikonStillReviewSelectionTests {
    @Test func classifiesReviewableFilenames() {
        #expect(NikonStillReviewObjectKind(filename: "DSC_0001.JPG") == .displayImage)
        #expect(NikonStillReviewObjectKind(filename: "dsc_0001.jpeg") == .displayImage)
        #expect(NikonStillReviewObjectKind(filename: "DSC_0001.HIF") == .displayImage)
        #expect(NikonStillReviewObjectKind(filename: "DSC_0001.NEF") == .raw)
        #expect(NikonStillReviewObjectKind(filename: "DSC_0001.NRW") == .raw)
        #expect(NikonStillReviewObjectKind(filename: "C0001.MOV") == nil)
    }

    @Test func rawPlusJPEGPrefersTheJPEGWhicheverArrivesFirst() {
        var nefFirst = NikonStillReviewSelection()
        let offered1 = nefFirst.offer(handle: 0x21, filename: "DSC_0012.NEF")
        #expect(!offered1)
        let offered2 = nefFirst.offer(handle: 0x20, filename: "DSC_0012.JPG")
        #expect(offered2)
        #expect(nefFirst.choice?.handle == 0x20)
        #expect(nefFirst.choice?.kind == .displayImage)

        var jpegFirst = NikonStillReviewSelection()
        let offered3 = jpegFirst.offer(handle: 0x21, filename: "DSC_0012.JPG")
        #expect(offered3)
        #expect(jpegFirst.choice?.handle == 0x21)
    }

    @Test func rawOnlyReviewsTheNEFAndStopsAtTheOlderShot() {
        var selection = NikonStillReviewSelection()
        let offered4 = selection.offer(handle: 0x31, filename: "C0004.MOV")
        #expect(!offered4)
        let offered5 = selection.offer(handle: 0x30, filename: "DSC_0013.NEF")
        #expect(!offered5)
        // An older shot's JPEG must not replace the new RAW-only frame.
        let offered6 = selection.offer(handle: 0x2F, filename: "DSC_0012.JPG")
        #expect(offered6)
        #expect(selection.choice?.handle == 0x30)
        #expect(selection.choice?.kind == .raw)
    }
}

@Suite("Instant review: object tracker")
struct NikonStillReviewObjectTrackerTests {
    private let card: UInt32 = 0x0001_0001

    private func objectAdded(_ handle: UInt32) -> PTPEvent {
        PTPEvent(eventCode: PTPEventCode.objectAdded.rawValue, parameters: [handle])
    }

    @Test func diffsAgainstTheSeededBaselineNewestFirst() {
        let tracker = NikonStillReviewObjectTracker()
        #expect(!tracker.hasBaseline)
        tracker.seed(listing: [card: [1, 2, 3]])
        #expect(tracker.hasBaseline)
        #expect(tracker.absorb(listing: [card: [1, 2, 3]]).isEmpty)
        #expect(tracker.absorb(listing: [card: [1, 2, 3, 4, 5]]) == [5, 4])
        // The listing became the baseline, so the same objects are not new again.
        #expect(tracker.absorb(listing: [card: [1, 2, 3, 4, 5]]).isEmpty)
    }

    @Test func withoutABaselineTheNewestListedObjectStandsIn() {
        let tracker = NikonStillReviewObjectTracker()
        #expect(tracker.absorb(listing: [card: [7, 9, 8]]) == [9])
    }

    @Test func aFailedCardListingKeepsItsBaseline() {
        let tracker = NikonStillReviewObjectTracker()
        tracker.seed(listing: [card: [1, 2], 0x0002_0001: [10]])
        // Card 2's listing failed this time: it must not be reset to empty.
        #expect(tracker.absorb(listing: [card: [1, 2, 3]]) == [3])
        #expect(tracker.absorb(listing: [card: [1, 2, 3], 0x0002_0001: [10, 11]]) == [11])
    }

    @Test func announcedHandlesComeNewestFirstAndOnlyOnce() {
        let tracker = NikonStillReviewObjectTracker()
        tracker.seed(listing: [card: [1]])
        tracker.note([
            objectAdded(5), objectAdded(6), objectAdded(6),
            PTPEvent(eventCode: PTPEventCode.captureComplete.rawValue, parameters: [99]),
        ])
        #expect(tracker.takeAnnounced() == [6, 5])
        #expect(tracker.takeAnnounced().isEmpty)
    }

    @Test func reviewedHandlesAreNeverOfferedByALaterDiff() {
        let tracker = NikonStillReviewObjectTracker()
        tracker.seed(listing: [card: [1]])
        tracker.note(objectAdded(2))
        tracker.markReviewed(tracker.takeAnnounced())
        // The next shot's announcement was lost: the diff must not fall back to the photo the
        // previous review already showed.
        #expect(tracker.absorb(listing: [card: [1, 2]]).isEmpty)
        #expect(tracker.absorb(listing: [card: [1, 2, 3]]) == [3])
        // A late duplicate announcement of a reviewed object is ignored too.
        tracker.markReviewed([3])
        tracker.note(objectAdded(3))
        #expect(tracker.takeAnnounced().isEmpty)
    }

    @Test func seedingForgetsOlderAnnouncements() {
        let tracker = NikonStillReviewObjectTracker()
        tracker.note(objectAdded(4))
        tracker.seed(listing: [card: [1, 4]])
        #expect(tracker.takeAnnounced().isEmpty)
    }
}

@Suite("Instant review: image reads")
struct NikonStillReviewImageReaderTests {
    /// Serves ranges of `bytes` and records each request.
    private final class Card {
        let bytes: [UInt8]
        var requests: [(offset: UInt32, length: UInt32)] = []
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        func read(_ offset: UInt32, _ length: UInt32) -> Data {
            requests.append((offset, length))
            let start = min(Int(offset), bytes.count)
            let end = min(start + Int(length), bytes.count)
            return Data(bytes[start..<end])
        }
    }

    @Test func streamsAWholeJPEGInChunks() {
        let card = Card((0..<2_500_000).map { UInt8(truncatingIfNeeded: $0) })
        let data = NikonStillReviewImageReader.read(
            kind: .displayImage, objectSize: 2_500_000, isCancelled: { false }
        ) { card.read($0, $1) }
        #expect(data == Data(card.bytes))
        #expect(card.requests.map(\.offset) == [0, 1_000_000, 2_000_000])
        #expect(card.requests.map(\.length) == [1_000_000, 1_000_000, 500_000])
    }

    @Test func readsOnlyTheHeadAndTheEmbeddedPreviewOfANEF() {
        let nef = NEFFixture.zStyleNEF(orientation: 1)
        let card = Card(nef.bytes)
        let data = NikonStillReviewImageReader.read(
            kind: .raw, objectSize: UInt32(nef.bytes.count), isCancelled: { false }
        ) { card.read($0, $1) }
        #expect(data == Data(nef.preview))
        #expect(card.requests.count == 2)
        #expect(card.requests.first?.offset == 0)
        #expect(card.requests.first?.length == NikonRawPreviewLocator.defaultHeadLength)
        #expect(card.requests.last?.offset == 300_000)
        #expect(card.requests.last?.length == 4_000)
    }

    @Test func aPortraitNEFPreviewCarriesItsOrientation() {
        let nef = NEFFixture.zStyleNEF(orientation: 6)
        let card = Card(nef.bytes)
        let data = NikonStillReviewImageReader.read(
            kind: .raw, objectSize: UInt32(nef.bytes.count), isCancelled: { false }
        ) { card.read($0, $1) }
        let expected = NikonRawPreviewLocator.taggingOrientation(
            Data(nef.preview), orientation: 6)
        #expect(data == expected)
    }

    @Test func aNEFWithoutAPreviewYieldsNothing() {
        let card = Card([UInt8](repeating: 0, count: 4_096))
        let data = NikonStillReviewImageReader.read(
            kind: .raw, objectSize: 4_096, isCancelled: { false }
        ) { card.read($0, $1) }
        #expect(data == nil)
        #expect(card.requests.count == 1)
    }

    @Test func cancellationStopsBeforeTheNextRead() {
        let card = Card([UInt8](repeating: 1, count: 3_000_000))
        let data = NikonStillReviewImageReader.read(
            kind: .displayImage, objectSize: 3_000_000,
            isCancelled: { card.requests.count >= 1 }
        ) { card.read($0, $1) }
        #expect(data == nil)
        #expect(card.requests.count == 1)
    }

    @Test func asyncReadMatchesTheBlockingRead() async {
        let nef = NEFFixture.zStyleNEF(orientation: 3)
        let bytes = nef.bytes
        let data = await NikonStillReviewImageReader.read(
            kind: .raw, objectSize: UInt32(bytes.count)
        ) { offset, length in
            let start = Int(offset)
            return Data(bytes[start..<min(start + Int(length), bytes.count)])
        }
        let expected = NikonRawPreviewLocator.taggingOrientation(
            Data(nef.preview), orientation: 3)
        #expect(data == expected)
    }
}

@Suite("Instant review: body capture attribution")
struct NikonBodyCaptureFilterTests {
    private func event(
        _ filter: inout NikonBodyCaptureFilter, at now: Int64, photo: Bool = true,
        review: Bool = true, inFlight: Bool = false
    ) -> NikonBodyCaptureSync {
        filter.action(
            at: now, isPhotography: photo, instantReviewEnabled: review,
            appReleaseInFlight: inFlight)
    }

    @Test func theLateHalfOfAnAppRawPlusJPEGPairIsNotABodyShot() {
        var filter = NikonBodyCaptureFilter()
        #expect(event(&filter, at: 0, inFlight: true) == .ignore)
        filter.appReleaseCompleted(at: 100)
        // The pair's second object lands after the release completed.
        #expect(event(&filter, at: 1_400) == .ignore)
    }

    @Test func lateObjectsOfAnAppBurstKeepExtendingTheTail() {
        var filter = NikonBodyCaptureFilter()
        filter.appReleaseCompleted(at: 0)
        let window = Int64(NikonStillReviewPolicy.objectWindowMilliseconds)
        #expect(event(&filter, at: window - 100) == .ignore)
        #expect(event(&filter, at: 2 * window - 300) == .ignore)
    }

    @Test func aBodyShotAfterTheTailIsReviewed() {
        var filter = NikonBodyCaptureFilter()
        filter.appReleaseCompleted(at: 0)
        let window = Int64(NikonStillReviewPolicy.objectWindowMilliseconds)
        #expect(event(&filter, at: window + 1) == .reviewAndShots)
    }

    @Test func aBodyRunSyncsOnce() {
        var filter = NikonBodyCaptureFilter()
        #expect(event(&filter, at: 10_000) == .reviewAndShots)
        #expect(event(&filter, at: 10_500) == .ignore)
        #expect(event(&filter, at: 11_200) == .ignore)
        #expect(event(&filter, at: 12_100) == .reviewAndShots)
    }

    @Test func movieModeAndReviewOffKeepTheirOldActions() {
        var filter = NikonBodyCaptureFilter()
        #expect(event(&filter, at: 0, photo: false) == .ignore)
        #expect(event(&filter, at: 0, review: false) == .shotsOnly)
    }
}
