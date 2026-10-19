import Foundation

/// One command dashboard value (Kotlin `MonitorCommandTile`). `kind` is the persisted reorder
/// identity (nil: the tile keeps its place); `request` is the host's write intent (nil: read-only).
public struct MonitorCommandTile<Kind: Hashable, Request> {
    public var kind: Kind?
    public var title: String
    public var value: String
    public var request: Request?
    public var unavailableReason: String?
    /// Accent-tinted side value (the prototype's `.cmd-stile.amber`).
    public var amber: Bool
    /// Dimmed side value (the prototype's `.cmd-stile.muted`), a placeholder with no write path.
    public var muted: Bool

    public init(
        kind: Kind? = nil, title: String, value: String, request: Request? = nil,
        unavailableReason: String? = nil, amber: Bool = false, muted: Bool = false
    ) {
        self.kind = kind
        self.title = title
        self.value = value
        self.request = request
        self.unavailableReason = unavailableReason
        self.amber = amber
        self.muted = muted
    }

    /// What a tap and a long press do now, spoken after the title and value (the Compose tile's
    /// content description without its leading "title: value"). `applying` is the host's answer
    /// for this tile's request; `reorderable` is false for a side cell, and a tile without a kind
    /// never offers a reorder.
    public func accessibilityHint(
        controlsEnabled: Bool, pending: Bool, applying: Bool, reorderable: Bool = true
    ) -> String {
        let reorder = reorderable && kind != nil
        let drag = reorder ? " Long press and drag to reorder." : ""
        if request != nil, pending, applying { return "Applying change." }
        if pending { return "Another control is being applied." }
        if request == nil { return (unavailableReason ?? "Read-only.") + drag }
        if !controlsEnabled { return "Controls are locked." + drag }
        return reorder ? "Double tap to change; long press and drag to reorder." : "Double tap to change."
    }
}

extension MonitorCommandTile: Equatable where Request: Equatable {}
extension MonitorCommandTile: Sendable where Kind: Sendable, Request: Sendable {}

/// One titled side-column group (Kotlin `MonitorCommandSection`). Cells pack two per row; a
/// leftover cell spans the row.
public struct MonitorCommandSection<Kind: Hashable, Request> {
    public var title: String
    public var cells: [MonitorCommandTile<Kind, Request>]

    public init(title: String, cells: [MonitorCommandTile<Kind, Request>]) {
        self.title = title
        self.cells = cells
    }
}

extension MonitorCommandSection: Equatable where Request: Equatable {}
extension MonitorCommandSection: Sendable where Kind: Sendable, Request: Sendable {}

/// The health strip readouts, formatted by the host (Kotlin `MonitorCommandHealth`).
/// `temperatureOk` paints the temperature good.
public struct MonitorCommandHealth: Equatable, Sendable {
    public var temperature: String
    public var temperatureOk: Bool
    public var storage: String
    public var camera: String
    public var lens: String

    public init(temperature: String, temperatureOk: Bool, storage: String, camera: String, lens: String) {
        self.temperature = temperature
        self.temperatureOk = temperatureOk
        self.storage = storage
        self.camera = camera
        self.lens = lens
    }
}

/// The dashboard's hero band reads the header's own `MonitorStatusPresentation`: its record word
/// (unknown is a dash, never standby) and its timecode, which a body without timecode leaves nil
/// so the hero shows no frozen 00:00:00:00 (Kotlin `MonitorStatusPresentation.commandHero*`).
extension MonitorStatusPresentation {
    /// The timecode split before its frame field (the part the accent paints); a value without a
    /// field separator is all seconds.
    public var commandHeroTimecode: (seconds: String, frames: String)? {
        guard let timecode, !timecode.isEmpty else { return nil }
        guard let split = timecode.lastIndex(where: { $0 == ":" || $0 == ";" }) else { return (timecode, "") }
        return (String(timecode[..<split]), String(timecode[split...]))
    }

    /// The hero's spoken value: the header's record words, then the timecode when there is one.
    public var commandHeroAccessibilityValue: String {
        [recordingAccessibilityLabel, timecode.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// Drops duplicates and kinds outside `all`, then appends the kinds the order lacks in `all`'s
/// order (Kotlin `monitorCommandTileOrder`).
public func monitorCommandTileOrder<Kind: Hashable>(_ order: [Kind], all: [Kind]) -> [Kind] {
    let known = Set(all)
    var seen = Set<Kind>()
    let unique = order.filter { known.contains($0) && seen.insert($0).inserted }
    return unique + all.filter { !seen.contains($0) }
}

/// Moves `kind` to `targetIndex` of the normalized order, keeping it complete (Kotlin
/// `moveMonitorCommandTile`). The target is clamped; a kind outside `all` changes nothing.
public func moveMonitorCommandTile<Kind: Hashable>(
    _ order: [Kind], _ kind: Kind, targetIndex: Int, all: [Kind]
) -> [Kind] {
    var normalized = monitorCommandTileOrder(order, all: all)
    guard let from = normalized.firstIndex(of: kind) else { return normalized }
    normalized.remove(at: from)
    normalized.insert(kind, at: min(max(targetIndex, 0), normalized.count))
    return normalized
}

/// The primary grid's cell size, measured once per layout pass.
public struct MonitorCommandGridCell: Equatable, Sendable {
    public var tileWidth: CGFloat
    public var rowHeight: CGFloat
    public var spacing: CGFloat
    public var columns: Int

    public init(tileWidth: CGFloat, rowHeight: CGFloat, spacing: CGFloat, columns: Int) {
        self.tileWidth = tileWidth
        self.rowHeight = rowHeight
        self.spacing = spacing
        self.columns = columns
    }
}

/// Command dashboard geometry. The constants and the rows, slot, hit and description rules are
/// the Compose dashboard's (`commandGridRows`, `commandGridSlot`, `commandGridHitSlot`,
/// `commandPortraitGridHeightDp`, `commandSideDescription`). The row cap, the tall value size and
/// the side column share are iOS only (see the MonitorUI README).
public enum MonitorCommandGridLayout {
    public static let columns = 3
    public static let spacing: CGFloat = 9
    public static let minimumRowHeight: CGFloat = 44
    /// iOS: a tablet grid never stretches a tile past a readable card.
    public static let maximumRowHeight: CGFloat = 150
    public static let portraitRowHeight: CGFloat = 76
    /// Landscape side column cell height (Kotlin `COMMAND_SIDE_TILE_MIN_HEIGHT`).
    public static let sideTileMinHeight: CGFloat = 42
    /// Portrait section cell height (Kotlin `COMMAND_PORTRAIT_SIDE_TILE_HEIGHT`).
    public static let portraitSideTileHeight: CGFloat = 44
    public static let cornerRadius: CGFloat = 12
    /// Seconds a drop or cancel keeps a tap from opening a tile.
    public static let reorderTapSuppression: TimeInterval = 0.15
    /// iOS long press before a tile lifts.
    public static let reorderPressDuration: TimeInterval = 0.3

    /// Rows of the primary grid.
    public static func rows(tileCount: Int, columns: Int = columns) -> Int {
        precondition(columns > 0, "Command dashboard grid needs at least one column.")
        return (max(tileCount, 1) + columns - 1) / columns
    }

    /// Resolves one drag position to a clamped row-major grid slot.
    public static func slot(
        at position: CGPoint, tileWidth: CGFloat, rowHeight: CGFloat, spacing: CGFloat, columns: Int,
        itemCount: Int
    ) -> Int {
        precondition(tileWidth > 0 && rowHeight > 0, "command grid cells must be positive")
        precondition(
            spacing >= 0 && columns > 0 && itemCount > 0, "command grid geometry must contain at least one item")
        let column = min(max(Int((position.x / (tileWidth + spacing)).rounded(.down)), 0), columns - 1)
        let row = max(Int((position.y / (rowHeight + spacing)).rounded(.down)), 0)
        return min(max(row * columns + column, 0), itemCount - 1)
    }

    /// Returns a tile only when a press lands inside its painted cell, never in a gutter.
    public static func hitSlot(
        at position: CGPoint, tileWidth: CGFloat, rowHeight: CGFloat, spacing: CGFloat, columns: Int,
        itemCount: Int
    ) -> Int? {
        precondition(tileWidth > 0 && rowHeight > 0, "command grid cells must be positive")
        precondition(
            spacing >= 0 && columns > 0 && itemCount > 0, "command grid geometry must contain at least one item")
        guard position.x >= 0, position.y >= 0 else { return nil }
        let columnStride = tileWidth + spacing
        let rowStride = rowHeight + spacing
        let column = Int((position.x / columnStride).rounded(.down))
        let row = Int((position.y / rowStride).rounded(.down))
        guard (0..<columns).contains(column),
            position.x - CGFloat(column) * columnStride < tileWidth,
            position.y - CGFloat(row) * rowStride < rowHeight
        else { return nil }
        let index = row * columns + column
        return (0..<itemCount).contains(index) ? index : nil
    }

    /// The compact portrait grid height, leaving the sections below it a scrollable region.
    public static func portraitGridHeight(tileCount: Int) -> CGFloat {
        let rows = rows(tileCount: tileCount)
        return CGFloat(rows) * portraitRowHeight + CGFloat(rows - 1) * spacing
    }

    /// Spoken label of the side column, from its section titles ("Image, Focus, and Audio controls.").
    public static func sideDescription(_ titles: [String]) -> String {
        let list: String
        switch titles.count {
        case 0, 1: list = titles.joined(separator: ", ")
        case 2: list = titles.joined(separator: " and ")
        default: list = titles.dropLast().joined(separator: ", ") + ", and " + (titles.last ?? "")
        }
        return list + " controls. Swipe up to reveal more command controls."
    }

    /// A landscape row fills its share of the grid height between a tap-target floor and the
    /// tablet cap.
    public static func rowHeight(height: CGFloat, rows: Int) -> CGFloat {
        min(maximumRowHeight, max(minimumRowHeight, (height - spacing * CGFloat(rows - 1)) / CGFloat(rows)))
    }

    /// Tall (tablet) tiles carry the value at dashboard scale; phone tiles keep 24 points.
    public static func valueFontSize(rowHeight: CGFloat) -> CGFloat { rowHeight > 120 ? 34 : 24 }

    /// The center of the tile at `index` in row-major order.
    public static func tileCenter(
        index: Int, tileWidth: CGFloat, rowHeight: CGFloat, spacing: CGFloat, columns: Int
    ) -> CGPoint {
        CGPoint(
            x: CGFloat(index % columns) * (tileWidth + spacing) + tileWidth / 2,
            y: CGFloat(index / columns) * (rowHeight + spacing) + rowHeight / 2)
    }

    /// The dragged tile's center: under the finger, kept whole inside the grid.
    public static func dragCenter(
        _ location: CGPoint, tileWidth: CGFloat, rowHeight: CGFloat, in size: CGSize
    ) -> CGPoint {
        func clamp(_ value: CGFloat, _ half: CGFloat, _ extent: CGFloat) -> CGFloat {
            min(max(value, half), max(half, extent - half))
        }
        return CGPoint(
            x: clamp(location.x, tileWidth / 2, size.width), y: clamp(location.y, rowHeight / 2, size.height))
    }

    /// Landscape side column width, both platforms: 27 percent of the dashboard, never under 160
    /// points (the baseline `.cmd-body` 2.35fr : 0.85fr split).
    public static func sideColumnWidth(pictureWidth: CGFloat) -> CGFloat { max(160, pictureWidth * 0.27) }

    /// Hero band height: portrait reserves the baseline 80 point band; landscape keeps the grid's
    /// rows readable under it.
    public static func heroHeight(portrait: Bool) -> CGFloat { portrait ? 80 : 56 }

    /// Hero timecode point size; long values scale down to `heroMinimumScale` before clipping.
    public static func heroTimecodeSize(portrait: Bool) -> CGFloat { portrait ? 60 : 46 }
    public static let heroMinimumScale: CGFloat = 0.5

    /// Gap between the hero, the health strip and the grid in the dashboard's left column.
    public static let stackSpacing: CGFloat = 8
}

/// The primary grid's reorder transaction (the Compose grid's drag callbacks and click
/// suppression). A long press lifts a tile only inside a painted cell that has a kind; each move
/// reports the slot when it differs from the tile's current one; a drop or cancel keeps a tap from
/// opening a tile for `MonitorCommandGridLayout.reorderTapSuppression` seconds.
public struct MonitorCommandGridDrag<Kind: Hashable> {
    public private(set) var kind: Kind?
    public private(set) var location: CGPoint = .zero
    private var suppressTapsUntil: TimeInterval = -.greatestFiniteMagnitude

    public init() {}

    /// Lifts the tile under `start`; false when there is none to lift.
    public mutating func begin(at start: CGPoint, kinds: [Kind?], cell: MonitorCommandGridCell) -> Bool {
        guard !kinds.isEmpty,
            let index = MonitorCommandGridLayout.hitSlot(
                at: start, tileWidth: cell.tileWidth, rowHeight: cell.rowHeight, spacing: cell.spacing,
                columns: cell.columns, itemCount: kinds.count),
            let kind = kinds[index]
        else { return false }
        self.kind = kind
        location = start
        suppressTapsUntil = .greatestFiniteMagnitude
        return true
    }

    /// Follows the finger; returns the target slot when the held tile should move there.
    public mutating func move(to point: CGPoint, kinds: [Kind?], cell: MonitorCommandGridCell) -> Int? {
        guard let kind, !kinds.isEmpty else { return nil }
        location = point
        let target = MonitorCommandGridLayout.slot(
            at: point, tileWidth: cell.tileWidth, rowHeight: cell.rowHeight, spacing: cell.spacing,
            columns: cell.columns, itemCount: kinds.count)
        return kinds.firstIndex(of: kind) == target ? nil : target
    }

    /// Drops (or cancels) the held tile at uptime `now`.
    public mutating func end(at now: TimeInterval) {
        if kind != nil { suppressTapsUntil = now + MonitorCommandGridLayout.reorderTapSuppression }
        kind = nil
    }

    /// Whether a tap at uptime `now` may open a tile.
    public func admitsTap(at now: TimeInterval) -> Bool { kind == nil && now >= suppressTapsUntil }
}
