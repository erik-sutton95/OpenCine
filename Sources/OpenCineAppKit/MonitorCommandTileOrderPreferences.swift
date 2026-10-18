import Foundation
import MonitorPresentation

/// The command dashboard tile order (Kotlin `MonitorCommandTileOrderPreferences`), stored as a
/// JSON array of raw values under the app's `key` in its own `storage`: the bytes
/// `JSONEncoder` writes for an array of the app's tile kinds, so an order an app stored that way
/// before this owner existed loads unchanged. Reads and writes are normalized over `all`: unknown
/// names drop out and tiles added later join at the end. Reading absent or malformed data never
/// rewrites the stored value.
public final class MonitorCommandTileOrderPreferences<Kind: RawRepresentable & Hashable>: @unchecked Sendable
where Kind.RawValue == String {
    private let storage: UserDefaults
    private let key: String
    private let all: [Kind]

    public init(storage: UserDefaults, key: String, all: [Kind]) {
        precondition(!key.isEmpty)
        self.storage = storage
        self.key = key
        self.all = all
    }

    public func load() -> [Kind] {
        let names = storage.data(forKey: key).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        return monitorCommandTileOrder(names?.compactMap(Kind.init(rawValue:)) ?? [], all: all)
    }

    public func save(_ order: [Kind]) {
        let names = monitorCommandTileOrder(order, all: all).map(\.rawValue)
        if let data = try? JSONEncoder().encode(names) { storage.set(data, forKey: key) }
    }
}
