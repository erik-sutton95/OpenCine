import Foundation

/// Decides which module window is on screen and where, from what the dock hears. Every module
/// window carries the tabs, so the selected module's window is the dock's window: it owns the
/// frame, the hidden ones are kept at that frame, and a tab switch only changes the order. The new
/// window comes in front first, and the old one goes when the new one reports `shown` (or the
/// switch times out), so the desktop never shows between them.
public struct DockWindowCoordinator: Sendable {
    public struct Command: Hashable, Sendable {
        public var moduleID: String
        public var message: DockMessage

        public init(moduleID: String, message: DockMessage) {
            self.moduleID = moduleID
            self.message = message
        }
    }

    public private(set) var selectedID: String?
    public private(set) var frame: WindowFrame
    /// Running modules, in the order they reported ready.
    private var running: [String] = []
    /// Modules told to show and not yet told to hide.
    private var visible: Set<String> = []

    public init(selectedID: String?, frame: WindowFrame) {
        self.selectedID = selectedID
        self.frame = frame
    }

    /// True when no running module can show the tabs, so the dock shows its own window.
    public var needsFallbackWindow: Bool { running.isEmpty }

    /// A module started (or restarted) and can take instructions. The selected one comes in front;
    /// while the selected one is not running yet and nothing is on screen, the first ready module
    /// stands in for it without taking the selection. Any other waits hidden at the current frame.
    public mutating func moduleReady(_ id: String) -> [Command] {
        if !running.contains(id) { running.append(id) }
        // A fresh process has nothing on screen yet.
        visible.remove(id)
        if selectedID == nil { selectedID = id }
        if id == selectedID || (!isRunning(selectedID) && visibleRunning.isEmpty) {
            return show(id)
        }
        return [Command(moduleID: id, message: .place(frame: frame)), Command(moduleID: id, message: .hide)]
    }

    /// A module's process ended. When it was the selected one, the next running module (in ready
    /// order) is selected and comes in front at the same frame.
    public mutating func moduleStopped(_ id: String) -> [Command] {
        running.removeAll { $0 == id }
        visible.remove(id)
        if id == selectedID {
            guard let next = running.first else { return [] }
            selectedID = next
            return show(next)
        }
        if !isRunning(selectedID), visibleRunning.isEmpty, let next = running.first {
            return show(next)
        }
        return []
    }

    /// The owner chose a tab. A running module is shown; the others stay until it reports `shown`.
    /// A module that is not running yet is shown when it reports ready.
    public mutating func select(_ id: String) -> [Command] {
        guard id != selectedID else { return [] }
        selectedID = id
        return isRunning(id) ? show(id) : []
    }

    /// The module's window is on screen: every other window that was showing goes.
    public mutating func moduleShown(_ id: String) -> [Command] {
        hideAllBut(id)
    }

    /// The module did not confirm `shown` in time: the others go anyway.
    public mutating func switchTimedOut(_ id: String) -> [Command] {
        hideAllBut(id)
    }

    /// The selected module's window moved or resized: the hidden ones follow, out of sight.
    public mutating func windowMoved(by id: String, to frame: WindowFrame) -> [Command] {
        guard id == selectedID, isRunning(id) else { return [] }
        self.frame = frame
        return running.filter { $0 != id }.map { Command(moduleID: $0, message: .place(frame: frame)) }
    }

    /// The owner asked for OpenCine, such as by clicking its Dock icon.
    public mutating func bringForward() -> [Command] {
        if let selectedID, isRunning(selectedID) { return show(selectedID) }
        return running.filter { visible.contains($0) }.map {
            Command(moduleID: $0, message: .show(frame: frame))
        }
    }

    private func isRunning(_ id: String?) -> Bool {
        id.map { running.contains($0) } ?? false
    }

    private var visibleRunning: [String] { running.filter { visible.contains($0) } }

    private mutating func show(_ id: String) -> [Command] {
        visible.insert(id)
        return [Command(moduleID: id, message: .show(frame: frame))]
    }

    private mutating func hideAllBut(_ id: String) -> [Command] {
        guard id == selectedID else { return [] }
        let leaving = visibleRunning.filter { $0 != id }
        visible = visible.intersection([id])
        return leaving.map { Command(moduleID: $0, message: .hide) }
    }
}
