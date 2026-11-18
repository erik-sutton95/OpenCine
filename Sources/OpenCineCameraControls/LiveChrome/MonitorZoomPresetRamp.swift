import Foundation
import MonitorPresentation
import OpenCineCameraVocabulary
import OpenCineMotion

/// One preset tap: the zoom to ask for over time, sampled from Motion Control's linear zoom
/// ramp (`NativeProgramZoom`). The host's continuous zoom path sends each sample, at the
/// gamepad zoom pump's cadence. Twin of Android `MonitorZoomPresetRamp`.
public struct MonitorZoomPresetRamp: Equatable, Sendable {
    public static let interval: TimeInterval = CamFov.zoomStepInterval

    public let from: Double
    public let to: Double
    public let duration: TimeInterval

    public init(from: Double, to: Double, duration: TimeInterval) {
        self.from = from
        self.to = to
        self.duration = duration
    }

    public func factor(at elapsed: TimeInterval) -> Double {
        guard duration > 0 else { return to }
        let demand = NativeProgramZoom.demand(
            from: from, to: to, duration: duration, elapsed: max(0, elapsed))
        if case .track(let factor) = demand.command { return factor }
        return to
    }

    public func isFinished(at elapsed: TimeInterval) -> Bool {
        duration <= 0 || !(elapsed < duration)
    }
}

/// Zoom presets under the app's existing `<prefix>.ZoomPresets` key. Reads never write.
public final class MonitorZoomPresetStore: @unchecked Sendable {
    // Configuration is immutable. UserDefaults synchronizes its individual reads and writes.
    private let storage: UserDefaults
    private let key: String

    public init(storage: UserDefaults, prefix: String) {
        precondition(!prefix.isEmpty)
        self.storage = storage
        self.key = prefix + ".ZoomPresets"
    }

    public var presets: MonitorZoomPresets {
        get { MonitorZoomPresets(stored: storage.string(forKey: key)) }
        set { storage.set(newValue.stored, forKey: key) }
    }
}
