import Foundation

/// The camera values beside the open View Assist palette. In landscape the open plate grows
/// trailing over the values strip; the values used to hide under it (hardware pass 1.1). They now
/// stay readable and tappable (owner decision 2026-10-28, hardware pass A2): with the plate open,
/// the strip lays its tiles out in the lane beside the plate.
///
/// The plate stays as wide as its catalog when the values fit beside it in one row. Otherwise the
/// values wrap into a second row above the first, where the trailing corner's controls (recenter,
/// AE unlock and a gimbal's stick and zoom) end that upper row early, and the plate gives up
/// width (its catalog scrolls) until every tile has at least `minimumTileWidth`. The plate keeps
/// `minimumPlateColumns`; only when the values still cannot fit beside that does the one row
/// scroll, the last resort.
///
/// Every target is fixed by the geometry, the tool count and the value count: nothing is measured,
/// so the host animates between the closed and the open arrangement without a layout feedback
/// loop. Portrait never moves the values: its plate grows upward above them.
/// Mirrors Kotlin `MonitorValuesReflow`.
public struct MonitorValuesReflow: Equatable, Sendable {
    /// The narrowest a reflowed tile gets: room for the longest caption whole ("SHUTTER", "PROFILE")
    /// and a value at its smallest scale.
    public static func minimumTileWidth(tablet: Bool) -> Double { tablet ? 72 : 64 }
    /// The widest a reflowed tile gets, so a roomy lane keeps the tiles together beside the plate.
    public static func maximumTileWidth(tablet: Bool) -> Double { tablet ? 120 : 104 }
    /// Space between two tiles, across and between rows (the portrait grid's spacing).
    public static let tileSpacing = 8.0
    /// The drawn height of one tile.
    public static let tileHeight = 34.0
    /// Space kept between the open plate, or a corner control, and the nearest tile.
    public static let clearance = 8.0
    /// Tool columns the open plate keeps however much room the values need.
    public static let minimumPlateColumns = 2

    /// The open plate's widest extent, from its leading edge. The host caps the palette with it in
    /// both states, so the plate never changes width while it opens.
    public let paletteWidth: Double
    /// Where the strip sits while the plate is open: bottom-aligned with the closed strip.
    public let values: MonitorRect
    /// Tiles per row, the top row first. One entry is one row.
    public let rows: [Int]
    /// Every tile's width while the plate is open.
    public let tileWidth: Double
    /// The last resort: one row that scrolls inside `values`.
    public let scrolls: Bool
    /// False when the plate never reaches the values (portrait, no values, or no tools): the
    /// strip keeps its own layout in both states.
    public let applies: Bool

    public init(
        paletteWidth: Double, values: MonitorRect, rows: [Int], tileWidth: Double, scrolls: Bool,
        applies: Bool
    ) {
        self.paletteWidth = paletteWidth; self.values = values; self.rows = rows
        self.tileWidth = tileWidth; self.scrolls = scrolls; self.applies = applies
    }

    /// The strip's frame for the palette state: the reflowed lane while open, else the closed strip.
    public func values(open: Bool, closed: MonitorRect) -> MonitorRect {
        applies && open ? values : closed
    }

    /// Whether the values keep their open arrangement. Opening a value's popup or its press and
    /// slide preview collapses the plate; the value under the finger stays where it was until
    /// that popup or preview ends, then the strip returns. `reflowed` is the previous answer.
    public static func reflowed(paletteOpen: Bool, capturePresented: Bool, reflowed: Bool) -> Bool {
        paletteOpen || (reflowed && capturePresented)
    }

    /// The trailing corner's controls the upper row stays clear of, for a camera with or without
    /// a motion cluster. Every slot is reserved whether or not it shows right now (AE unlock shows
    /// only while exposure is locked), so the values never move when one appears.
    public static func cornerControls(_ geometry: FieldMonitorLayout, motionCluster: Bool) -> [MonitorRect] {
        let reset = geometry.focusReset(motionCluster: motionCluster)
        let unlock = geometry.aeUnlock(motionCluster: motionCluster)
        return motionCluster
            ? [geometry.stick, geometry.zoom, geometry.gimbal, geometry.headTrack, reset, unlock]
            : [reset, unlock]
    }

    /// The open catalog's width before any cap: the palette's own `fieldMonitor` width.
    static func catalogWidth(_ geometry: FieldMonitorLayout, toolCount: Int) -> Double {
        let cell = MonitorSystemButtonMetrics.side(tablet: geometry.tablet)
        let columns = max(1, (max(0, toolCount) + 1) / 2)
        let catalog = Double(columns) * cell + Double(columns - 1) * MonitorAssistPaletteLayout.spacing
            + MonitorAssistPaletteLayout.horizontalInsets
        return min(
            max(1, geometry.values.maxX - geometry.assists.x),
            max(cell + MonitorAssistPaletteLayout.horizontalInsets, catalog))
    }

    public static func fieldMonitor(
        _ geometry: FieldMonitorLayout, toolCount: Int, valueCount: Int,
        cornerControls: [MonitorRect]
    ) -> Self {
        let closed = geometry.values
        let full = catalogWidth(geometry, toolCount: toolCount)
        let unchanged = Self(
            paletteWidth: full, values: closed, rows: [max(0, valueCount)], tileWidth: 0,
            scrolls: false, applies: false)
        let x0 = geometry.assists.x
        let cell = MonitorSystemButtonMetrics.side(tablet: geometry.tablet)
        // The open landscape plate: two cells and its insets tall, on the collapsed slot's bottom.
        let plateHeight = 2 * cell + 11
        let openPlate = MonitorRect(
            x: x0, y: geometry.assists.maxY - plateHeight, width: full, height: plateHeight)
        guard !geometry.portrait, valueCount > 0, toolCount > 0, closed.width > 0, closed.height > 0,
            MonitorAssistPaletteReveal.coversValues(palette: openPlate, values: closed)
        else { return unchanged }

        let minimumPlate = min(
            full,
            Double(minimumPlateColumns) * cell
                + Double(minimumPlateColumns - 1) * MonitorAssistPaletteLayout.spacing
                + MonitorAssistPaletteLayout.horizontalInsets)
        let tile = minimumTileWidth(tablet: geometry.tablet)
        let pitch = tile + tileSpacing
        let bottom = closed.maxY
        let lowerTop = bottom - tileHeight
        let upperTop = lowerTop - tileSpacing - tileHeight
        // A row ends a clearance before the first corner control that shares its band, and never
        // past the closed strip's trailing edge (the rail).
        func end(top: Double, bottom: Double) -> Double {
            cornerControls.filter {
                $0.width > 0 && $0.height > 0 && $0.y < bottom && $0.maxY > top
                    && $0.maxX > x0 + minimumPlate
            }.map { $0.x - clearance }.reduce(closed.maxX, min)
        }
        let lowerEnd = end(top: lowerTop, bottom: bottom)
        let upperEnd = end(top: upperTop, bottom: lowerTop - tileSpacing)
        // The furthest the lane may start for `count` tiles to fit a row ending at `rowEnd`.
        func start(_ count: Int, _ rowEnd: Double) -> Double {
            count == 0 ? .infinity : rowEnd + tileSpacing - Double(count) * pitch
        }
        // Each split of the values (upper row, lower row) admits a lane start; the plate takes
        // the widest that any split allows. Ties keep one row, then the fuller lower row.
        var best: (plate: Double, upper: Int)?
        for upper in 0...valueCount {
            let lower = valueCount - upper
            guard lower >= upper || upper == 0 else { break }
            let laneStart = min(start(lower, lowerEnd), start(upper, upperEnd))
            let plate = min(full, laneStart - clearance - x0)
            if plate >= minimumPlate, best.map({ plate > $0.plate }) ?? true { best = (plate, upper) }
        }
        guard let chosen = best else {
            // Last resort: the plate keeps its minimum and the one row scrolls beside it.
            let laneX = x0 + minimumPlate + clearance
            return Self(
                paletteWidth: minimumPlate,
                values: MonitorRect(x: laneX, y: closed.y, width: max(0, lowerEnd - laneX), height: closed.height),
                rows: [valueCount], tileWidth: tile, scrolls: true, applies: true)
        }
        let laneX = x0 + chosen.plate + clearance
        // At the chosen plate, balance the rows: the upper row takes half, or fewer when the lower
        // row has room for more, and never more than fits before the corner controls.
        func fits(_ rowEnd: Double) -> Int { max(0, Int(((rowEnd - laneX + tileSpacing) / pitch + 1e-9).rounded(.down))) }
        let lowerFits = fits(lowerEnd)
        let upper: Int
        if valueCount <= lowerFits { upper = 0 } else {
            upper = min(fits(upperEnd), max(valueCount - lowerFits, valueCount / 2))
        }
        let lower = valueCount - upper
        func room(_ count: Int, _ rowEnd: Double) -> Double {
            count == 0 ? .infinity : (rowEnd - laneX - Double(count - 1) * tileSpacing) / Double(count)
        }
        let width = min(maximumTileWidth(tablet: geometry.tablet), room(lower, lowerEnd), room(upper, upperEnd))
        let rows = upper == 0 ? [lower] : [upper, lower]
        let height = Double(rows.count) * tileHeight + Double(rows.count - 1) * tileSpacing
        let laneHeight = max(closed.height, height)
        return Self(
            paletteWidth: chosen.plate,
            values: MonitorRect(
                x: laneX, y: bottom - laneHeight, width: max(0, lowerEnd - laneX), height: laneHeight),
            rows: rows, tileWidth: width, scrolls: false, applies: true)
    }

    /// The tiles' frames while the plate is open, row by row from the lane's leading edge, rows
    /// bottom-aligned with the closed strip. A scrolling row lays out past the lane's end.
    public var tiles: [MonitorRect] {
        guard applies else { return [] }
        var frames: [MonitorRect] = []
        for (index, count) in rows.enumerated() {
            let y = values.maxY - Double(rows.count - index) * Self.tileHeight
                - Double(rows.count - 1 - index) * Self.tileSpacing
            for column in 0..<count {
                frames.append(MonitorRect(
                    x: values.x + Double(column) * (tileWidth + Self.tileSpacing), y: y,
                    width: tileWidth, height: Self.tileHeight))
            }
        }
        return frames
    }
}
