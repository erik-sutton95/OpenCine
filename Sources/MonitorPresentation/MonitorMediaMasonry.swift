import Foundation

/// The media grid's staggered (masonry) placement. Items keep the displayed order, and each one
/// goes into the column that is shortest so far (the leftmost on a tie), so every column stacks
/// its cards tightly with no row gaps. A card is as tall as its picture at the column width
/// plus the caption. The picture's shape comes from metadata known before any thumbnail loads
/// (``uprightAspect(width:height:exifOrientation:)``), so loading thumbnails never moves a card,
/// and listing more items never moves the ones already placed.
///
/// Kotlin twin: Compose `LazyVerticalStaggeredGrid` places the same way (shortest lane first,
/// leftmost on a tie) from the card heights `MonitorClipCard` gives it through the same aspect.
public struct MonitorMediaMasonry: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
        public let column: Int
        public let x: Double
        public let y: Double
        public let width: Double
        /// The whole card: picture plus caption.
        public let height: Double
        /// Width over height of the card's picture.
        public let aspect: Double

        public func contains(x px: Double, y py: Double) -> Bool {
            px >= x && px < x + width && py >= y && py < y + height
        }
    }

    /// The shape of a picture not known yet: most clips are 16:9.
    public static let defaultAspect = 16.0 / 9.0
    /// Shapes outside this range (panoramas, slivers) are drawn cropped to it.
    public static let aspectRange: ClosedRange<Double> = 0.5...2.5

    /// Item indices per column, top to bottom.
    public let columns: [[Int]]
    /// One frame per item, in the displayed order.
    public let frames: [Frame]

    public init(
        aspects: [Double?], columnCount: Int, width: Double, spacing: Double,
        captionHeight: Double
    ) {
        let count = max(1, columnCount)
        let columnWidth = max(0, (width - spacing * Double(count - 1)) / Double(count))
        var bottoms = [Double](repeating: 0, count: count)
        var columns = [[Int]](repeating: [], count: count)
        var frames: [Frame] = []
        frames.reserveCapacity(aspects.count)
        for (index, value) in aspects.enumerated() {
            var column = 0
            for candidate in 1..<count where bottoms[candidate] < bottoms[column] {
                column = candidate
            }
            let aspect = Self.aspect(value)
            let height = columnWidth / aspect + captionHeight
            frames.append(
                Frame(
                    column: column, x: Double(column) * (columnWidth + spacing),
                    y: bottoms[column], width: columnWidth, height: height, aspect: aspect))
            columns[column].append(index)
            bottoms[column] += height + spacing
        }
        self.columns = columns
        self.frames = frames
    }

    /// The card under a point in the grid's coordinates; nil between cards.
    public func index(atX x: Double, y: Double) -> Int? {
        guard let column = frames.first(where: { x >= $0.x && x < $0.x + $0.width })?.column else {
            return nil
        }
        return columns[column].first { frames[$0].contains(x: x, y: y) }
    }

    /// A drawable picture shape: unknown or invalid values take ``defaultAspect``, others are
    /// held to ``aspectRange``.
    public static func aspect(_ value: Double?) -> Double {
        guard let value, value.isFinite, value > 0 else { return defaultAspect }
        return min(aspectRange.upperBound, max(aspectRange.lowerBound, value))
    }

    /// Width over height of a picture as it is shown: stored pixel dimensions, turned for an
    /// EXIF orientation of 5 to 8 (a quarter turn). Nil when the dimensions are unknown.
    public static func uprightAspect(width: Int?, height: Int?, exifOrientation: Int? = nil)
        -> Double?
    {
        guard let width, let height, width > 0, height > 0 else { return nil }
        let quarterTurn = (5...8).contains(exifOrientation ?? 1)
        return quarterTurn ? Double(height) / Double(width) : Double(width) / Double(height)
    }
}
