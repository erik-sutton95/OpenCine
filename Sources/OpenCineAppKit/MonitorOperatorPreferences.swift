import Foundation

/// Common operator choices stored under the app's existing keys and defaults domain.
/// Reads preserve absence and explicit false; opening settings performs no migration writes.
public final class MonitorOperatorPreferences: @unchecked Sendable {
    public struct Keys: Sendable {
        public let keepScreenAwake: String
        public let hdrDisplay: String
        public let recordConfirmation: String
        public let haptics: String
        public let cacheOriginals: String
        public let legacyKeepScreenAwake: String?

        public init(
            keepScreenAwake: String, hdrDisplay: String, recordConfirmation: String,
            haptics: String, cacheOriginals: String, legacyKeepScreenAwake: String? = nil
        ) {
            let keys = [keepScreenAwake, hdrDisplay, recordConfirmation, haptics, cacheOriginals]
            precondition(keys.allSatisfy { !$0.isEmpty } && Set(keys).count == keys.count)
            self.keepScreenAwake = keepScreenAwake
            self.hdrDisplay = hdrDisplay
            self.recordConfirmation = recordConfirmation
            self.haptics = haptics
            self.cacheOriginals = cacheOriginals
            self.legacyKeepScreenAwake = legacyKeepScreenAwake
        }
    }

    public struct Defaults: Sendable {
        public var keepScreenAwake: Bool
        public var hdrDisplay: Bool
        public var recordConfirmation: Bool
        public var haptics: Bool
        public var cacheOriginals: Bool

        public init(
            keepScreenAwake: Bool = true, hdrDisplay: Bool = false,
            recordConfirmation: Bool = true, haptics: Bool = true, cacheOriginals: Bool = true
        ) {
            self.keepScreenAwake = keepScreenAwake
            self.hdrDisplay = hdrDisplay
            self.recordConfirmation = recordConfirmation
            self.haptics = haptics
            self.cacheOriginals = cacheOriginals
        }
    }

    // Configuration is immutable. UserDefaults synchronizes its individual reads and writes.
    private let storage: UserDefaults
    private let keys: Keys
    private let defaults: Defaults

    public init(storage: UserDefaults, keys: Keys, defaults: Defaults = .init()) {
        self.storage = storage
        self.keys = keys
        self.defaults = defaults
    }

    public var keepScreenAwake: Bool {
        get {
            if storage.object(forKey: keys.keepScreenAwake) != nil {
                return storage.bool(forKey: keys.keepScreenAwake)
            }
            if let legacy = keys.legacyKeepScreenAwake, storage.object(forKey: legacy) != nil {
                return storage.bool(forKey: legacy)
            }
            return defaults.keepScreenAwake
        }
        set { storage.set(newValue, forKey: keys.keepScreenAwake) }
    }
    public var hdrDisplay: Bool {
        get { read(keys.hdrDisplay, fallback: defaults.hdrDisplay) }
        set { storage.set(newValue, forKey: keys.hdrDisplay) }
    }
    public var recordConfirmation: Bool {
        get { read(keys.recordConfirmation, fallback: defaults.recordConfirmation) }
        set { storage.set(newValue, forKey: keys.recordConfirmation) }
    }
    public var haptics: Bool {
        get { read(keys.haptics, fallback: defaults.haptics) }
        set { storage.set(newValue, forKey: keys.haptics) }
    }
    public var cacheOriginals: Bool {
        get { read(keys.cacheOriginals, fallback: defaults.cacheOriginals) }
        set { storage.set(newValue, forKey: keys.cacheOriginals) }
    }

    private func read(_ key: String, fallback: Bool) -> Bool {
        storage.object(forKey: key) == nil ? fallback : storage.bool(forKey: key)
    }
}
