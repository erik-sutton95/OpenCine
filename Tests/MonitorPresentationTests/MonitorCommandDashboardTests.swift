import Foundation
import MonitorPresentation
import Testing

/// The SwiftUI twin's values and geometry. The order, slot and description cases are the Kotlin
/// `MonitorCommandDashboardTest` cases, so both platforms keep one contract.
struct MonitorCommandDashboardTests {
    private enum Tile: String, CaseIterable, Hashable { case a, b, c, d, e, f, g, h }

    private struct Write: Equatable { let setting: String }

    @Test func orderDropsDuplicatesAndUnknownsAndAppendsNewTiles() {
        let all = Tile.allCases
        #expect(monitorCommandTileOrder([], all: all) == all)
        #expect(
            monitorCommandTileOrder([.e, .b, .e], all: all)
                == [.e, .b] + all.filter { ![.e, .b].contains($0) })
        #expect(monitorCommandTileOrder(["x", "b"], all: ["a", "b"]) == ["b", "a"])
    }

    @Test func moveKeepsTheOrderCompleteAndClampsTheTarget() {
        let order = Tile.allCases
        let moved = moveMonitorCommandTile(order, .a, targetIndex: 3, all: order)
        #expect(moved == [.b, .c, .d, .a, .e, .f, .g, .h])
        #expect(moveMonitorCommandTile(moved, .a, targetIndex: 99, all: order).last == .a)
        #expect(moveMonitorCommandTile(order, .h, targetIndex: -4, all: order).first == .h)
        #expect(moveMonitorCommandTile(order, .c, targetIndex: 2, all: order) == order)
        // A duplicated stored order is repaired by the move itself.
        #expect(Set(moveMonitorCommandTile([.b, .b], .b, targetIndex: 5, all: order)) == Set(order))
    }

    @Test func tilesCarryTheHostsTypedKindAndRequest() {
        let tile = MonitorCommandTile(kind: Tile.c, title: "ISO", value: "800", request: Write(setting: "iso"))
        #expect(tile.kind == .c)
        #expect(tile.request == Write(setting: "iso"))
        let readOnly = MonitorCommandTile<Tile, Write>(
            title: "Grid", value: "OFF", unavailableReason: "Read-only here.")
        #expect(readOnly.kind == nil)
        #expect(readOnly.request == nil)
        #expect(!readOnly.amber && !readOnly.muted)
    }

    @Test func gridRowsAndPortraitHeight() {
        #expect(MonitorCommandGridLayout.rows(tileCount: 0) == 1)
        #expect(MonitorCommandGridLayout.rows(tileCount: 1) == 1)
        #expect(MonitorCommandGridLayout.rows(tileCount: 9) == 3)
        #expect(MonitorCommandGridLayout.rows(tileCount: 10) == 4)
        #expect(MonitorCommandGridLayout.rows(tileCount: 10, columns: 2) == 5)
        #expect(MonitorCommandGridLayout.portraitGridHeight(tileCount: 1) == 76)
        #expect(MonitorCommandGridLayout.portraitGridHeight(tileCount: 9) == 246)
    }

    @Test func dragResolvesEveryEdgeToAValidSlot() {
        func slot(_ x: CGFloat, _ y: CGFloat) -> Int {
            MonitorCommandGridLayout.slot(
                at: CGPoint(x: x, y: y), tileWidth: 100, rowHeight: 60, spacing: 9, columns: 3,
                itemCount: 8)
        }
        #expect(slot(-50, -20) == 0)
        #expect(slot(115, 72) == 4)
        #expect(slot(900, 900) == 7)
    }

    @Test func aDragStartsOnlyInsideAPaintedTile() {
        func hit(_ x: CGFloat, _ y: CGFloat) -> Int? {
            MonitorCommandGridLayout.hitSlot(
                at: CGPoint(x: x, y: y), tileWidth: 100, rowHeight: 60, spacing: 9, columns: 3,
                itemCount: 8)
        }
        #expect(hit(115, 72) == 4)
        #expect(hit(105, 20) == nil)  // gutter
        #expect(hit(20, 65) == nil)  // gutter
        #expect(hit(230, 150) == nil)  // empty slot
        #expect(hit(-1, 10) == nil)
    }

    @Test func theSideColumnIsSpokenFromItsSectionTitles() {
        #expect(
            MonitorCommandGridLayout.sideDescription(["Image", "Focus", "Audio", "Monitor"])
                == "Image, Focus, Audio, and Monitor controls. Swipe up to reveal more command controls.")
        #expect(
            MonitorCommandGridLayout.sideDescription(["Image", "Focus"])
                == "Image and Focus controls. Swipe up to reveal more command controls.")
        #expect(
            MonitorCommandGridLayout.sideDescription(["Audio"])
                == "Audio controls. Swipe up to reveal more command controls.")
    }

    // iOS geometry the Compose dashboard does not share (recorded in the MonitorUI README).

    @Test func rowsFillTheHeightBetweenAReadableFloorAndATabletCap() {
        // Phone landscape: three rows share the grid height.
        #expect(MonitorCommandGridLayout.rowHeight(height: 240, rows: 3) == 74)
        // Never shorter than a tap target, never a slab taller than a readable card.
        #expect(MonitorCommandGridLayout.rowHeight(height: 60, rows: 3) == 44)
        #expect(MonitorCommandGridLayout.rowHeight(height: 900, rows: 3) == 150)
        #expect(MonitorCommandGridLayout.valueFontSize(rowHeight: 74) == 24)
        #expect(MonitorCommandGridLayout.valueFontSize(rowHeight: 150) == 34)
    }

    @Test func tilesSitInRowMajorSlotsAndADraggedTileStaysInTheGrid() {
        let center = MonitorCommandGridLayout.tileCenter(
            index: 4, tileWidth: 100, rowHeight: 60, spacing: 9, columns: 3)
        #expect(center == CGPoint(x: 159, y: 99))
        let size = CGSize(width: 318, height: 189)
        func drag(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            MonitorCommandGridLayout.dragCenter(
                CGPoint(x: x, y: y), tileWidth: 100, rowHeight: 60, in: size)
        }
        #expect(drag(150, 90) == CGPoint(x: 150, y: 90))
        #expect(drag(-40, -40) == CGPoint(x: 50, y: 30))
        #expect(drag(900, 900) == CGPoint(x: 268, y: 159))
    }

    @Test func theSideColumnKeepsItsShareOfThePicture() {
        #expect(MonitorCommandGridLayout.sideColumnWidth(pictureWidth: 852) == 852 * 0.27)
        #expect(MonitorCommandGridLayout.sideColumnWidth(pictureWidth: 400) == 160)
    }

    // The Compose grid's drag lambdas (onDragStart, onDrag, onDragEnd, onDragCancel and the click
    // suppression) as one value both gesture owners can be checked against.

    private let cell = MonitorCommandGridCell(tileWidth: 100, rowHeight: 60, spacing: 9, columns: 3)

    @Test func aLongPressPicksUpOnlyAReorderableTileUnderTheFinger() {
        let kinds: [Tile?] = [.a, .b, nil, .d]
        var drag = MonitorCommandGridDrag<Tile>()
        func lift(_ x: CGFloat, _ y: CGFloat) -> Bool {
            drag.begin(at: CGPoint(x: x, y: y), kinds: kinds, cell: cell)
        }
        #expect(!lift(105, 20), "A gutter lifts nothing")
        #expect(!lift(250, 20), "A tile without a kind keeps its place")
        #expect(drag.kind == nil)
        #expect(drag.admitsTap(at: 0))
        #expect(lift(150, 20))
        #expect(drag.kind == .b)
        #expect(drag.location == CGPoint(x: 150, y: 20))
        #expect(!drag.admitsTap(at: .greatestFiniteMagnitude), "No tap lands while a tile is held")
    }

    @Test func aHeldTileAsksToMoveOnlyWhenItsSlotChanges() {
        var kinds: [Tile?] = [.a, .b, .c, .d]
        var drag = MonitorCommandGridDrag<Tile>()
        func move(_ x: CGFloat, _ y: CGFloat) -> Int? {
            drag.move(to: CGPoint(x: x, y: y), kinds: kinds, cell: cell)
        }
        #expect(move(250, 20) == nil, "Nothing held")
        _ = drag.begin(at: CGPoint(x: 20, y: 20), kinds: kinds, cell: cell)
        #expect(move(40, 30) == nil)
        #expect(drag.location == CGPoint(x: 40, y: 30))
        #expect(move(250, 20) == 2)
        kinds = [.b, .c, .a, .d]
        #expect(move(260, 25) == nil)
        // Past the last tile resolves to the last slot.
        #expect(move(900, 900) == 3)
    }

    @Test func aDropOrCancelSuppressesTapsBriefly() {
        let kinds: [Tile?] = [.a, .b]
        var drag = MonitorCommandGridDrag<Tile>()
        drag.end(at: 10)
        #expect(drag.admitsTap(at: 10), "Ending with nothing held suppresses nothing")
        _ = drag.begin(at: CGPoint(x: 20, y: 20), kinds: kinds, cell: cell)
        drag.end(at: 10)
        #expect(drag.kind == nil)
        #expect(!drag.admitsTap(at: 10.149))
        #expect(drag.admitsTap(at: 10 + MonitorCommandGridLayout.reorderTapSuppression))
    }

    @Test func tileHintsSayWhatATapAndALongPressDo() {
        let open = MonitorCommandTile(kind: Tile.a, title: "ISO", value: "800", request: Write(setting: "iso"))
        let fixed = MonitorCommandTile<Tile, Write>(title: "Grid", value: "OFF")
        let reorderOnly = MonitorCommandTile<Tile, Write>(
            kind: .b, title: "Codec", value: "N-RAW", unavailableReason: "Wait for the camera.")
        func hint(_ tile: MonitorCommandTile<Tile, Write>, enabled: Bool = true, pending: Bool = false,
            applying: Bool = false) -> String
        {
            tile.accessibilityHint(controlsEnabled: enabled, pending: pending, applying: applying)
        }
        #expect(hint(open) == "Double tap to change; long press and drag to reorder.")
        #expect(hint(open, enabled: false) == "Controls are locked. Long press and drag to reorder.")
        #expect(hint(open, pending: true) == "Another control is being applied.")
        #expect(hint(open, pending: true, applying: true) == "Applying change.")
        #expect(hint(reorderOnly) == "Wait for the camera. Long press and drag to reorder.")
        // A tile with no kind keeps its place, so it never offers a reorder.
        #expect(hint(fixed) == "Read-only.")
        #expect(fixed.accessibilityHint(controlsEnabled: false, pending: false, applying: false) == "Read-only.")
        #expect(
            open.accessibilityHint(controlsEnabled: true, pending: false, applying: false, reorderable: false)
                == "Double tap to change.")
    }

    @Test func heroReadsTheHeaderStatusAndSplitsTheFrameField() {
        let recording = MonitorStatusPresentation(recording: true, timecode: "01:02:03:04")
        #expect(recording.commandHeroTimecode?.seconds == "01:02:03")
        #expect(recording.commandHeroTimecode?.frames == ":04")
        #expect(recording.commandHeroAccessibilityValue == "Recording, 01:02:03:04")
        // Drop-frame timecode keeps its semicolon in the accent field.
        #expect(MonitorStatusPresentation(recording: false, timecode: "01:02:03;04").commandHeroTimecode?.frames == ";04")
        #expect(MonitorStatusPresentation(recording: false, timecode: "12").commandHeroTimecode?.seconds == "12")
        // Unknown never reads as standby; a body with no timecode has no hero digits.
        let unknown = MonitorStatusPresentation(recording: nil, timecode: nil)
        #expect(unknown.recordingLabel == "--")
        #expect(unknown.commandHeroTimecode == nil)
        #expect(unknown.commandHeroAccessibilityValue == "Recording state unknown")
        #expect(MonitorStatusPresentation(recording: false, timecode: "").commandHeroTimecode == nil)
        #expect(MonitorStatusPresentation(recording: false, timecode: "").commandHeroAccessibilityValue == "Standby")
    }

    @Test func heroAndSideColumnGeometryMatchTheComposeTwin() {
        #expect(MonitorCommandGridLayout.heroHeight(portrait: true) == 80)
        #expect(MonitorCommandGridLayout.heroHeight(portrait: false) == 56)
        #expect(MonitorCommandGridLayout.heroTimecodeSize(portrait: true) == 60)
        #expect(MonitorCommandGridLayout.heroTimecodeSize(portrait: false) == 46)
        // The hero fits its band.
        for portrait in [true, false] {
            #expect(
                MonitorCommandGridLayout.heroTimecodeSize(portrait: portrait)
                    < MonitorCommandGridLayout.heroHeight(portrait: portrait))
        }
        #expect(MonitorCommandGridLayout.sideColumnWidth(pictureWidth: 400) == 160)
        #expect(MonitorCommandGridLayout.sideColumnWidth(pictureWidth: 1000) == 270)
    }
}
