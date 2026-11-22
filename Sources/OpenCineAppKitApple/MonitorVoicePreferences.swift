#if os(iOS)
import Foundation
import Observation
import OpenCineAppKit

public enum MonitorVoiceAction: String, CaseIterable, Identifiable {
    case start, stop, preset, lens

    public var id: String { rawValue }

    fileprivate init(_ command: VoiceCommand) {
        switch command {
        case .start: self = .start
        case .stop: self = .stop
        case .preset, .nextPreset, .previousPreset: self = .preset
        case .switchLens: self = .lens
        }
    }
}

@MainActor @Observable
public final class MonitorVoicePreferences {
    private static let key = "monitor.voice.actions"
    private let storage: UserDefaults
    private var overrides: [String: Bool]

    public init(storage: UserDefaults = .standard) {
        self.storage = storage
        let saved = storage.dictionary(forKey: Self.key) as? [String: Bool] ?? [:]
        overrides = saved.filter { MonitorVoiceAction(rawValue: $0.key) != nil }
    }

    public func isEnabled(_ action: MonitorVoiceAction) -> Bool {
        overrides[action.rawValue] ?? (action != .lens)
    }

    public func setEnabled(_ enabled: Bool, for action: MonitorVoiceAction) {
        overrides[action.rawValue] = enabled
        storage.set(overrides, forKey: Self.key)
    }

    public func allows(_ command: VoiceCommand, supportsLens: Bool = false) -> Bool {
        let action = MonitorVoiceAction(command)
        return (action != .lens || supportsLens) && isEnabled(action)
    }

    public func availableActions(supportsLens: Bool) -> [MonitorVoiceAction] {
        MonitorVoiceAction.allCases.filter { $0 != .lens || supportsLens }
    }
}
#endif
