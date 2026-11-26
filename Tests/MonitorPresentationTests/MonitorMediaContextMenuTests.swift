import MonitorPresentation
import Testing

/// The Mac's right-click menu on a Media cell offers what the catalog already offers for that item
/// and source, and acts on the whole selection where the selection bar does
/// (spec 2026-11-26-desktop-tabs-take-in-feed-design.md, section 6).
struct MonitorMediaContextMenuTests {
    private static let all: MonitorMediaPermissions = [.favorite, .share, .delete]

    private func menu(
        _ id: String = "A", favorite: Bool = false,
        permissions: MonitorMediaPermissions = all, selecting: Bool = false,
        selected: Set<String> = [], allowed: [String: MonitorMediaPermissions] = [:]
    ) -> MonitorMediaContextMenu {
        MonitorMediaContextMenu(
            item: id, favorite: favorite, permissions: permissions, selecting: selecting,
            selectedIDs: selected, selectedPermissions: { allowed[$0] ?? Self.all })
    }

    @Test func browsingOffersEveryActionTheItemAllows() {
        let value = menu()
        #expect(value.commands == [.open, .favorite, .share, .select, .delete])
        #expect(value.entries.allSatisfy { $0.enabled })
        #expect(value.entry(.open)?.actions == [.open("A")])
        #expect(value.entry(.favorite)?.actions == [.favorite("A")])
        #expect(value.entry(.select)?.actions == [.select("A")])
        #expect(value.entry(.delete)?.destructive == true)
        #expect(value.entry(.share)?.destructive == false)
    }

    @Test func aFavoriteOffersUnfavorite() {
        let value = menu(favorite: true)
        #expect(value.commands.contains(.unfavorite))
        #expect(!value.commands.contains(.favorite))
        #expect(value.entry(.unfavorite)?.title == "Unfavorite")
        #expect(value.entry(.unfavorite)?.actions == [.favorite("A")])
    }

    /// A source that cannot share or delete this item (a clip only on the camera with no download,
    /// a card that is read-only) shows those entries disabled, as the selection bar does.
    @Test func whatTheSourceDoesNotAllowIsShownDisabled() {
        let value = menu(permissions: [.favorite])
        #expect(value.entry(.share)?.enabled == false)
        #expect(value.entry(.delete)?.enabled == false)
        #expect(value.entry(.favorite)?.enabled == true)
        #expect(value.entry(.open)?.enabled == true)

        let none = menu(permissions: [])
        #expect(none.entry(.favorite)?.enabled == false)
        #expect(none.entry(.share)?.enabled == false)
        #expect(none.entry(.delete)?.enabled == false)
    }

    /// Browsing, share and delete act on the clicked item alone and leave selection mode off.
    @Test func browsingSharesAndDeletesTheItemAloneThenLeavesSelection() {
        let value = menu()
        #expect(value.entry(.share)?.actions == [.selection(["A"]), .shareSelection, .clearSelection])
        #expect(value.entry(.delete)?.actions == [.selection(["A"]), .deleteSelection, .clearSelection])
        #expect(value.entry(.share)?.title == "Share…")
        #expect(value.entry(.delete)?.title == "Delete…")
    }

    @Test func insideASelectionShareAndDeleteActOnTheWholeSelection() {
        let value = menu(selecting: true, selected: ["A", "B", "C"])
        #expect(value.commands == [.share, .deselect, .delete])
        #expect(value.entry(.share)?.actions == [.shareSelection])
        #expect(value.entry(.delete)?.actions == [.deleteSelection])
        #expect(value.entry(.share)?.title == "Share 3 Items…")
        #expect(value.entry(.delete)?.title == "Delete 3 Items…")
        #expect(value.entry(.deselect)?.actions == [.select("A")])
    }

    /// Every selected item must allow the action, as on the selection bar.
    @Test func aSelectionAllowsOnlyWhatEverySelectedItemAllows() {
        let value = menu(
            selecting: true, selected: ["A", "B"], allowed: ["B": [.favorite, .share]])
        #expect(value.entry(.share)?.enabled == true)
        #expect(value.entry(.delete)?.enabled == false)
    }

    /// One selected item is still one item: its star stays in the menu.
    @Test func aSelectionOfOneKeepsTheStar() {
        let value = menu(selecting: true, selected: ["A"])
        #expect(value.commands == [.favorite, .share, .deselect, .delete])
        #expect(value.entry(.share)?.actions == [.shareSelection])
    }

    /// In selection mode a click toggles rather than opens, so the menu has no Open; an item outside
    /// the selection is shared or deleted alone and the selection is put back.
    @Test func outsideTheSelectionTheItemActsAloneAndTheSelectionComesBack() {
        let value = menu(selecting: true, selected: ["B", "C"])
        #expect(value.commands == [.favorite, .share, .select, .delete])
        #expect(
            value.entry(.share)?.actions
                == [.selection(["A"]), .shareSelection, .selection(["B", "C"])])
        #expect(
            value.entry(.delete)?.actions
                == [.selection(["A"]), .deleteSelection, .selection(["B", "C"])])
        #expect(value.entry(.share)?.title == "Share…")
        #expect(value.entry(.select)?.actions == [.select("A")])
    }

    @Test func noEntryUsesAnEmDash() {
        for value in [menu(), menu(favorite: true), menu(selecting: true, selected: ["A", "B"])] {
            #expect(!value.entries.contains { $0.title.contains("\u{2014}") })
        }
    }
}
