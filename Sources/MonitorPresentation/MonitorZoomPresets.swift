import Foundation

/// The operator's saved zoom amounts and the one ramp time a preset tap uses.
///
/// Values only: the adapter's existing continuous zoom path moves the camera, and the
/// current FORMAT's limit decides which presets a tap may ask for. Twin of Android
/// `monitor-ui` `MonitorZoomPresets`.
public struct MonitorZoomPresets: Equatable, Sendable {
    public static let slotCount = 3
    /// Off (a jump), then 0.5 s steps up to 10 s.
    public static let rampChoices: [Double] = [0] + (1...20).map { Double($0) / 2 }

    public private(set) var slots: [Double?]
    public private(set) var rampSeconds: Double

    public init(slots: [Double?] = [], rampSeconds: Double = 0) {
        self.slots = (0..<Self.slotCount).map { index in
            index < slots.count ? slots[index].flatMap(Self.shown) : nil
        }
        self.rampSeconds = Self.snappedRamp(rampSeconds)
    }

    /// Stores the zoom as the chip shows it (a tenth). Saving over a slot replaces it.
    public mutating func save(_ factor: Double, at index: Int) {
        guard slots.indices.contains(index), let shown = Self.shown(factor) else { return }
        slots[index] = shown
    }

    public mutating func setRamp(_ seconds: Double) {
        rampSeconds = Self.snappedRamp(seconds)
    }

    /// The zoom a tap on `index` asks for: nothing for an empty slot or one past the current limit.
    public func target(at index: Int, maximum: Double) -> Double? {
        guard slots.indices.contains(index), let saved = slots[index], maximum.isFinite,
            saved <= maximum + 0.05 else { return nil }
        return min(saved, maximum)
    }

    public static func rampLabel(_ seconds: Double) -> String {
        let snapped = snappedRamp(seconds)
        if snapped == 0 { return "Off" }
        return snapped == snapped.rounded() ? "\(Int(snapped)) s" : "\(snapped) s"
    }

    /// `<ramp>|<slot>,<slot>,<slot>`; an empty slot is empty text.
    public var stored: String {
        "\(rampSeconds)|" + slots.map { $0.map { "\($0)" } ?? "" }.joined(separator: ",")
    }

    /// Unreadable text reads as no presets and no ramp; readable parts are kept.
    public init(stored: String?) {
        let parts = (stored ?? "").split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            self.init()
            return
        }
        let slots = parts[1].split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
        self.init(slots: slots, rampSeconds: Double(parts[0]) ?? 0)
    }

    private static func shown(_ factor: Double) -> Double? {
        guard factor.isFinite, factor > 0 else { return nil }
        return max(1, (factor * 10).rounded() / 10)
    }

    private static func snappedRamp(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        return rampChoices.min { abs($0 - seconds) < abs($1 - seconds) } ?? 0
    }
}
