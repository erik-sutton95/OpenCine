import Foundation
import MonitorPresentation
import Observation
import OpenCineMedia

@available(macOS 14, *)
@MainActor @Observable
public final class MonitorNDPreferenceStore {
    @ObservationIgnored private let storage: UserDefaults
    @ObservationIgnored private let key: String
    public var scale: Double
    public var notation: MonitorNDFilterNotation
    public var position: MonitorScopeStoredCenter?
    public var positionPortrait: MonitorScopeStoredCenter?

    public init(storage: UserDefaults, key: String) {
        precondition(!key.isEmpty)
        self.storage = storage; self.key = key
        if let data = storage.data(forKey: key),
            let snapshot = try? JSONDecoder().decode(MonitorNDOptions.self, from: data) {
            scale = min(max(snapshot.scale, 0.6), 1.6)
            notation = snapshot.notation ?? .factor
            position = snapshot.position; positionPortrait = snapshot.positionPortrait
        } else {
            scale = 1; notation = .factor; position = nil; positionPortrait = nil
        }
    }
    public func persist() {
        let snapshot = MonitorNDOptions(scale: min(max(scale, 0.6), 1.6),
            position: position, positionPortrait: positionPortrait, notation: notation)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        storage.set(data, forKey: key)
    }
}

@available(macOS 14, *)
@MainActor @Observable
public final class MonitorTrafficLightsPreferenceStore {
    @ObservationIgnored private let storage: UserDefaults
    @ObservationIgnored private let key: String
    public var compensation: MonitorCrushClipCompensation
    public var scale: Double
    public var position: MonitorScopeStoredCenter?
    public var positionPortrait: MonitorScopeStoredCenter?

    public init(storage: UserDefaults, key: String, histogram: MonitorScopePanelStore<MonitorHistogramOptions>) {
        precondition(!key.isEmpty)
        self.storage = storage; self.key = key
        if let data = storage.data(forKey: key),
            let snapshot = try? JSONDecoder().decode(MonitorTrafficLightsOptions.self, from: data) {
            compensation = snapshot.compensation
            scale = min(max(snapshot.scale, 0.6), 1.6)
            position = snapshot.position; positionPortrait = snapshot.positionPortrait
        } else {
            compensation = histogram.options.crushClipCompensation
            scale = 1; position = nil; positionPortrait = nil
        }
        histogram.options.crushClipCompensation = compensation
    }
    public func persist() {
        let snapshot = MonitorTrafficLightsOptions(compensation: compensation, scale: min(max(scale, 0.6), 1.6),
            position: position, positionPortrait: positionPortrait)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        storage.set(data, forKey: key)
    }
}
