import Foundation
import MonitorPresentation

/// The existing assist-usage schema under an app-supplied defaults domain and key.
/// Reading absent or malformed data never rewrites the operator's stored value.
public final class MonitorToolUsagePreferences: @unchecked Sendable {
    private let storage: UserDefaults
    private let key: String

    public init(storage: UserDefaults, key: String) {
        precondition(!key.isEmpty)
        self.storage = storage
        self.key = key
    }

    public var value: MonitorToolUsage {
        get {
            guard let data = storage.data(forKey: key),
                let value = try? JSONDecoder().decode(MonitorToolUsage.self, from: data)
            else { return MonitorToolUsage() }
            return value
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                storage.set(data, forKey: key)
            }
        }
    }
}
