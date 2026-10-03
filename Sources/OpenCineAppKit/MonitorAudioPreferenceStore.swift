import Foundation
import MonitorPresentation
import Observation

@available(macOS 14, *)
@MainActor @Observable
public final class MonitorAudioPreferenceStore {
    @ObservationIgnored private let storage: UserDefaults
    @ObservationIgnored private let key: String
    public var options: MonitorAudioOptions

    public init(storage: UserDefaults, key: String) {
        precondition(!key.isEmpty)
        self.storage = storage; self.key = key
        options = storage.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(MonitorAudioOptions.self, from: $0) } ?? .init()
    }
    public func storedCenter(in slot: MonitorScopeCanvasSlot) -> MonitorAudioStoredCenter? {
        slot == .portrait ? options.portraitCenter : options.landscapeCenter
    }
    public func setCenter(_ center: MonitorScopePoint, canvas: MonitorRect) {
        let stored = MonitorAudioStoredCenter(x: (center.x - canvas.x) / max(1, canvas.width),
            y: (center.y - canvas.y) / max(1, canvas.height))
        if canvas.height > canvas.width { options.portraitCenter = stored }
        else { options.landscapeCenter = stored }
        persist()
    }
    public func persist() {
        guard let data = try? JSONEncoder().encode(options) else { return }
        storage.set(data, forKey: key)
    }
}

@available(macOS 14, *)
@MainActor @Observable
public final class MonitorFalseColorReferencePositionStore {
    @ObservationIgnored private let storage: UserDefaults
    @ObservationIgnored private let key: String
    public var positions: MonitorFalseColorReferencePositions

    public init(storage: UserDefaults, key: String) {
        precondition(!key.isEmpty)
        self.storage = storage; self.key = key
        positions = storage.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(MonitorFalseColorReferencePositions.self, from: $0) } ?? .init()
    }
    public func setCenter(_ center: MonitorScopePoint, canvas: MonitorRect) {
        let stored = MonitorFalseColorReferencePositions.Center(x: (center.x - canvas.x) / max(1, canvas.width),
            y: (center.y - canvas.y) / max(1, canvas.height))
        if canvas.height > canvas.width { positions.portrait = stored } else { positions.landscape = stored }
        guard let data = try? JSONEncoder().encode(positions) else { return }
        storage.set(data, forKey: key)
    }
}
