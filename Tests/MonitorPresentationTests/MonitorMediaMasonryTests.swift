import MonitorPresentation
import Testing

/// The media grid's staggered placement (REQ-MEDIA-THUMB-ORIENTATION follow-up): every item
/// stacks under the previous one in its column, with no row gaps.
struct MonitorMediaMasonryTests {
    private static let landscape = 16.0 / 9.0
    private static let portrait = 2.0 / 3.0

    private func masonry(_ aspects: [Double?], columns: Int = 2) -> MonitorMediaMasonry {
        MonitorMediaMasonry(
            aspects: aspects, columnCount: columns, width: 410, spacing: 10, captionHeight: 40)
    }

    @Test func eachItemInSortOrderGoesIntoTheShortestColumn() {
        // Column width 200: a landscape card is 112.5 + 40 tall, a portrait card 300 + 40.
        let layout = masonry([Self.portrait, Self.landscape, Self.landscape, Self.landscape])

        #expect(layout.columns == [[0], [1, 2, 3]])
        #expect(layout.frames.map(\.column) == [0, 1, 1, 1])
        // Items stack tightly: each starts one spacing below the previous card in its column.
        #expect(layout.frames[2].y == layout.frames[1].y + layout.frames[1].height + 10)
        #expect(layout.frames[3].y == layout.frames[2].y + layout.frames[2].height + 10)
        #expect(layout.frames[0].height == 340)
        #expect(layout.frames[1].height == 152.5)
        #expect(layout.frames[1].x == 210)
    }

    @Test func aTieGoesToTheLeftmostColumn() {
        let layout = masonry([Self.landscape, Self.landscape, Self.landscape], columns: 3)
        #expect(layout.columns == [[0], [1], [2]])
        let next = masonry(
            [Self.landscape, Self.landscape, Self.landscape, Self.landscape], columns: 3)
        #expect(next.frames[3].column == 0)
    }

    @Test func oneColumnStacksEveryItemInOrder() {
        let layout = masonry([Self.portrait, Self.landscape, nil], columns: 1)
        #expect(layout.columns == [[0, 1, 2]])
        #expect(layout.frames.map(\.width) == [410, 410, 410])
    }

    @Test func anUnknownShapeTakesTheClipShapeAndPicturesStayInARange() {
        let layout = masonry([nil, 0, -1, .infinity, .nan, 40, 0.05])
        let aspects = layout.frames.map(\.aspect)
        #expect(aspects[0] == MonitorMediaMasonry.defaultAspect)
        #expect(aspects[1...4].allSatisfy { $0 == MonitorMediaMasonry.defaultAspect })
        #expect(aspects[5] == MonitorMediaMasonry.aspectRange.upperBound)
        #expect(aspects[6] == MonitorMediaMasonry.aspectRange.lowerBound)
    }

    /// Placement depends only on metadata, so loading thumbnails (which changes no aspect) and
    /// listing more items never moves an item already placed.
    @Test func placementHoldsWhileThumbnailsLoadAndMoreItemsArrive() {
        let first: [Double?] = [Self.landscape, Self.portrait, nil, Self.landscape, Self.portrait]
        let shown = masonry(first)
        #expect(masonry(first) == shown)

        let more = masonry(first + [Self.portrait, Self.landscape, nil])
        #expect(Array(more.frames.prefix(first.count)) == shown.frames)
    }

    @Test func aStillsUprightShapeFollowsItsExifOrientation() {
        let stored = (width: 6048, height: 4032)
        #expect(
            MonitorMediaMasonry.uprightAspect(
                width: stored.width, height: stored.height, exifOrientation: 1) == 1.5)
        #expect(
            MonitorMediaMasonry.uprightAspect(
                width: stored.width, height: stored.height, exifOrientation: 3) == 1.5)
        for turned in [5, 6, 7, 8] {
            #expect(
                MonitorMediaMasonry.uprightAspect(
                    width: stored.width, height: stored.height, exifOrientation: turned)
                    == 4032.0 / 6048.0)
        }
        #expect(
            MonitorMediaMasonry.uprightAspect(
                width: stored.width, height: stored.height, exifOrientation: nil) == 1.5)
        #expect(MonitorMediaMasonry.uprightAspect(width: nil, height: 4032) == nil)
        #expect(MonitorMediaMasonry.uprightAspect(width: 0, height: 4032) == nil)
    }

    @Test func aPointResolvesToTheStaggeredCardUnderIt() {
        let layout = masonry([Self.portrait, Self.landscape, Self.landscape, Self.landscape])
        // Beside the tall portrait, the right column holds three short cards.
        #expect(layout.index(atX: 100, y: 330) == 0)
        #expect(layout.index(atX: 300, y: 10) == 1)
        #expect(layout.index(atX: 300, y: 170) == 2)
        #expect(layout.index(atX: 300, y: 330) == 3)
        // The gap between columns and the space under a short column hold no card.
        #expect(layout.index(atX: 205, y: 100) == nil)
        #expect(layout.index(atX: 100, y: 345) == nil)
    }

    /// Hold on the tall portrait, then drag across to the third card of the other column: the
    /// sweep runs through the displayed order between them, as in the uniform grid.
    @Test func aDragAcrossStaggeredCardsSelectsTheDisplayedRange() throws {
        let ids = ["a", "b", "c", "d", "e"]
        let layout = masonry([
            Self.portrait, Self.landscape, Self.landscape, Self.landscape, Self.landscape,
        ])
        let origin = try #require(layout.index(atX: 100, y: 50))
        var sweep = try #require(
            MonitorMediaDragSelection(orderedIDs: ids, originID: ids[origin], selectedIDs: []))
        let over = try #require(layout.index(atX: 300, y: 330))
        sweep.move(to: over)
        #expect(sweep.selectedIDs == ["a", "b", "c", "d"])
        let back = try #require(layout.index(atX: 300, y: 10))
        sweep.move(to: back)
        #expect(sweep.selectedIDs == ["a", "b"])
    }
}
