import Foundation
import MonitorPresentation
import Observation

/// Owns saved options and the two session placement slots. Storage and namespace are app inputs.
@available(macOS 14, *)
@MainActor @Observable
public final class MonitorScopePanelStore<Options: MonitorScopePanelOptions> {
    @ObservationIgnored private let storage: UserDefaults
    @ObservationIgnored private let key: String
    public var options: Options { didSet { persist() } }
    public var sessionPosition: MonitorScopePoint?
    public var sessionPositionPortrait: MonitorScopePoint?

    public init(options: Options? = nil, storage: UserDefaults, key: String) {
        precondition(!key.isEmpty)
        self.storage = storage; self.key = key
        self.options = options ?? Self.load(storage: storage, key: key)
    }
    public static func load(storage: UserDefaults, key: String) -> Options {
        guard let data = storage.data(forKey: key),
            let decoded = try? JSONDecoder().decode(Options.self, from: data) else { return .default }
        return decoded
    }
    public func persist() {
        guard let data = try? JSONEncoder().encode(options) else { return }
        storage.set(data, forKey: key)
    }
    public func setScale(_ scale: Double) {
        var next = options
        next.scale = Options.clampedScale(scale); next.hasCustomScale = true
        options = next
    }
    public func presentationScale(width: Double, height: Double, tablet: Bool) -> Double {
        guard width > 1, height > 1 else { return options.scale }
        return MonitorScopeSizing.scale(portrait: height > width, tablet: tablet,
            preferred: options.hasCustomScale ? options.scale : nil)
    }
    public func sessionPosition(in slot: MonitorScopeCanvasSlot) -> MonitorScopePoint? {
        slot == .portrait ? sessionPositionPortrait : sessionPosition
    }
    public func storedCenter(in slot: MonitorScopeCanvasSlot) -> MonitorScopeStoredCenter? {
        slot == .portrait ? options.storedCenterPortrait : options.storedCenter
    }
    public func beginDrag(center: MonitorScopePoint, slot: MonitorScopeCanvasSlot) {
        if slot == .portrait { sessionPositionPortrait = center } else { sessionPosition = center }
    }
    public func drag(to center: MonitorScopePoint, slot: MonitorScopeCanvasSlot) {
        beginDrag(center: center, slot: slot)
    }
    public func cancelDrag(slot: MonitorScopeCanvasSlot) {
        if slot == .portrait { sessionPositionPortrait = nil } else { sessionPosition = nil }
    }
    public func endDrag(canvas: MonitorRect) {
        let slot = MonitorScopeCanvasSlot.forSize(width: canvas.width, height: canvas.height)
        guard let center = sessionPosition(in: slot) else { return }
        let stored = MonitorScopeStoredCenter(xFraction: (center.x - canvas.x) / max(canvas.width, 1),
            yFraction: (center.y - canvas.y) / max(canvas.height, 1))
        var next = options
        if slot == .portrait { next.storedCenterPortrait = stored } else { next.storedCenter = stored }
        options = next
    }
}
