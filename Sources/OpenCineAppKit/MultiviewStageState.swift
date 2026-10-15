import Foundation
import MonitorPresentation
import Observation

/// Stable presentation values, independent of camera membership and network cleanup.
public enum MultiviewStageLayout: String, Codable, CaseIterable, Sendable {
    case grid = "2 × 2 grid"
    case centerStage = "Center stage"

    public var arrangement: MultiviewPresentationLayout.Arrangement {
        self == .grid ? .grid : .centerStage
    }
}

public struct MultiviewStagePreferences: Codable, Equatable, Sendable {
    public var layout: MultiviewStageLayout
    public var selected: Int
    public var fill: Bool
    public var clean: Bool
    public var toolsExpanded: Bool
    public var toolUsage: MonitorToolUsage

    public init(
        layout: MultiviewStageLayout = .centerStage, selected: Int = 0, fill: Bool = false,
        clean: Bool = false, toolsExpanded: Bool = false, toolUsage: MonitorToolUsage = .init()
    ) {
        self.layout = layout
        self.selected = selected
        self.fill = fill
        self.clean = clean
        self.toolsExpanded = toolsExpanded
        self.toolUsage = toolUsage
    }

    private enum CodingKeys: String, CodingKey {
        case layout, selected, fill, clean, toolsExpanded, toolUsage
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        layout =
            try values.decodeIfPresent(MultiviewStageLayout.self, forKey: .layout) ?? .centerStage
        selected = try values.decodeIfPresent(Int.self, forKey: .selected) ?? 0
        fill = try values.decodeIfPresent(Bool.self, forKey: .fill) ?? false
        clean = try values.decodeIfPresent(Bool.self, forKey: .clean) ?? false
        toolsExpanded = try values.decodeIfPresent(Bool.self, forKey: .toolsExpanded) ?? false
        toolUsage = try values.decodeIfPresent(MonitorToolUsage.self, forKey: .toolUsage) ?? .init()
    }
}

/// The coordinator owns this state; transient editors, popups and sessions never enter it.
@available(macOS 14, *)
@MainActor @Observable
public final class MultiviewStageState {
    public private(set) var preferences = MultiviewStagePreferences()
    @ObservationIgnored private let slotCount: Int
    @ObservationIgnored private var save: ((MultiviewStagePreferences) -> Bool)?
    @ObservationIgnored private var hasStoredPreferences = false

    public init(slotCount: Int) {
        precondition(slotCount > 0)
        self.slotCount = slotCount
    }

    public var layout: MultiviewStageLayout {
        get { preferences.layout }
        set {
            var next = preferences
            next.layout = newValue
            update(next)
        }
    }
    public var selected: Int {
        get { preferences.selected }
        set {
            var next = preferences
            next.selected = newValue
            update(next)
        }
    }
    public var fill: Bool {
        get { preferences.fill }
        set {
            var next = preferences
            next.fill = newValue
            update(next)
        }
    }
    public var clean: Bool {
        get { preferences.clean }
        set {
            var next = preferences
            next.clean = newValue
            update(next)
        }
    }
    public var toolsExpanded: Bool {
        get { preferences.toolsExpanded }
        set {
            var next = preferences
            next.toolsExpanded = newValue
            update(next)
        }
    }
    public var toolUsage: MonitorToolUsage {
        get { preferences.toolUsage }
        set {
            var next = preferences
            next.toolUsage = newValue
            update(next)
        }
    }

    public func attachPersistence(
        load: () -> MultiviewStagePreferences?, save: @escaping (MultiviewStagePreferences) -> Bool
    ) {
        self.save = save
        if let stored = load() {
            preferences = normalized(stored)
            hasStoredPreferences = true
        }
    }

    /// A deployed app's old journal may seed presentation once, never overwrite a newer store.
    public func importLegacy(_ value: MultiviewStagePreferences) {
        if !hasStoredPreferences { update(value) }
    }

    private func normalized(_ value: MultiviewStagePreferences) -> MultiviewStagePreferences {
        var next = value
        next.selected = min(slotCount - 1, max(0, next.selected))
        return next
    }

    private func update(_ value: MultiviewStagePreferences) {
        let next = normalized(value)
        guard next != preferences else { return }
        preferences = next
        if save?(next) == true { hasStoredPreferences = true }
    }
}

/// The app supplies its existing preference domain and a presentation-only key.
public final class MultiviewStagePreferencesStore {
    private let storage: UserDefaults
    private let key: String

    public init(storage: UserDefaults, key: String) {
        precondition(!key.isEmpty)
        self.storage = storage
        self.key = key
    }

    public func load() -> MultiviewStagePreferences? {
        guard let data = storage.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(MultiviewStagePreferences.self, from: data)
    }

    @discardableResult public func save(_ value: MultiviewStagePreferences) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        storage.set(data, forKey: key)
        return true
    }
}

public enum MultiviewNetworkRestore: Sendable {
    case none
    case cameraNetworks

    public var closeQuestion: String {
        switch self {
        case .none: "Close Multiview? Recording continues."
        case .cameraNetworks:
            "Close Multiview and return cameras to their own Wi-Fi? Recording continues."
        }
    }
    public static let closeAction = "Close monitoring"
}
