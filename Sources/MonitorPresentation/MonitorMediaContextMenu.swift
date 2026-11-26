import Foundation

/// A Mac's right-click menu on one Media cell. It offers only what the catalog already offers for
/// that item: open (as a click does), favorite (as the cell's star does), select, and share and
/// delete with the selection bar's rules. Each entry is the catalog intents it sends, in order, so
/// the menu reaches no I/O of its own and a camera source keeps its own operations.
///
/// Right-clicking an item inside a selection acts on the whole selection where the selection bar
/// can (share, delete); anywhere else it acts on that item alone and leaves the selection as it was.
public struct MonitorMediaContextMenu: Equatable, Sendable {
    public enum Command: String, CaseIterable, Equatable, Sendable {
        case open, favorite, unfavorite, select, deselect, share, delete
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public let command: Command
        public let title: String
        /// Shown but not chosen, as the selection bar and the cell's star show what the source does
        /// not allow.
        public let enabled: Bool
        public let actions: [MonitorMediaAction]
        public var id: Command { command }
        public var destructive: Bool { command == .delete }
    }

    public let entries: [Entry]

    public var commands: [Command] { entries.map(\.command) }

    public func entry(_ command: Command) -> Entry? { entries.first { $0.command == command } }

    /// - Parameters:
    ///   - selectedPermissions: what each selected item allows; nil for an item no longer shown.
    public init(
        item id: String, favorite: Bool, permissions: MonitorMediaPermissions,
        selecting: Bool, selectedIDs: Set<String>,
        selectedPermissions: (String) -> MonitorMediaPermissions?
    ) {
        let inSelection = selecting && selectedIDs.contains(id)
        // The items share and delete act on, and what each allows.
        let group: [MonitorMediaPermissions] =
            inSelection ? selectedIDs.compactMap(selectedPermissions) : [permissions]
        let count = inSelection ? selectedIDs.count : 1
        func allows(_ permission: MonitorMediaPermissions) -> Bool {
            !group.isEmpty && group.allSatisfy { $0.contains(permission) }
        }
        /// The selection bar's intent, on this item alone when it is not in the selection: select
        /// it, run the intent, then put back the selection as it was.
        func onSelection(_ action: MonitorMediaAction) -> [MonitorMediaAction] {
            if inSelection { return [action] }
            return [.selection([id]), action, selecting ? .selection(selectedIDs) : .clearSelection]
        }
        let suffix = count > 1 ? " \(count) Items" : ""

        var entries: [Entry] = []
        // A click opens only while browsing; in selection mode it toggles the item instead.
        if !selecting {
            entries.append(Entry(command: .open, title: "Open", enabled: true, actions: [.open(id)]))
        }
        // The star is one item's; a selection has no favorite action.
        if count == 1 {
            entries.append(
                Entry(
                    command: favorite ? .unfavorite : .favorite,
                    title: favorite ? "Unfavorite" : "Favorite",
                    enabled: permissions.contains(.favorite), actions: [.favorite(id)]))
        }
        entries.append(
            Entry(command: .share, title: "Share\(suffix)…", enabled: allows(.share),
                actions: onSelection(.shareSelection)))
        entries.append(
            inSelection
                ? Entry(command: .deselect, title: "Deselect", enabled: true, actions: [.select(id)])
                : Entry(command: .select, title: "Select", enabled: true, actions: [.select(id)]))
        entries.append(
            Entry(command: .delete, title: "Delete\(suffix)…", enabled: allows(.delete),
                actions: onSelection(.deleteSelection)))
        self.entries = entries
    }
}
