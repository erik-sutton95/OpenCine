import Observation

/// Operator display intent and the editor's return path. Sources supply admitted mode order;
/// this owner has no camera command, preference namespace or knowledge of a mode's features.
@available(macOS 14, *)
@MainActor @Observable
public final class MonitorDisplaySession<Mode: Equatable> {
    public var mode: Mode
    public var locked = false
    public var editingMode: Mode?
    public var returnedMode: Mode?

    public init(mode: Mode) { self.mode = mode }

    public var isEditing: Bool { editingMode != nil }

    @discardableResult public func select(_ next: Mode, order: [Mode]) -> Bool {
        guard !locked, next != mode, order.contains(next) else { return false }
        mode = next
        return true
    }

    @discardableResult public func cycle(order: [Mode]) -> Bool {
        guard !locked, let next = Self.next(in: order, after: mode) else { return false }
        return select(next, order: order)
    }

    /// A disabled cycle mode may still be edited. Ending the editor reconciles the live mode.
    public func beginEditing(_ mode: Mode) {
        self.mode = mode
        editingMode = mode
    }

    @discardableResult public func finishEditing(order: [Mode]) -> Mode? {
        guard let edited = editingMode else { return nil }
        returnedMode = edited
        editingMode = nil
        reconcile(order: order)
        return edited
    }

    @discardableResult public func reconcile(order: [Mode]) -> Bool {
        guard !order.contains(mode), let first = order.first else { return false }
        mode = first
        return true
    }

    /// Retire only presentation. The current mode and interface lock stay operator intent.
    public func retireEditor() { editingMode = nil; returnedMode = nil }

    public static func next(in order: [Mode], after current: Mode) -> Mode? {
        guard !order.isEmpty else { return nil }
        guard let index = order.firstIndex(of: current) else { return order[0] }
        return order[(index + 1) % order.count]
    }
}
