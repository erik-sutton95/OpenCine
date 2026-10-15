import Foundation
import Observation

/// Common operator choices stored under the app's existing keys and defaults domain.
/// Reads preserve absence and explicit false; opening settings performs no migration writes.
/// Each choice is observable, so a root that reads one (screen wake) follows a Settings write.
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
    // Observation is macOS 14; the package keeps macOS 13 for host tests, so the registrar
    // (itself Sendable) is held untyped.
    private let observation: any Sendable = {
        if #available(macOS 14, *) { return ObservationRegistrar() }
        return ()
    }()

    public init(storage: UserDefaults, keys: Keys, defaults: Defaults = .init()) {
        self.storage = storage
        self.keys = keys
        self.defaults = defaults
    }

    public var keepScreenAwake: Bool {
        get {
            access(\.keepScreenAwake)
            if storage.object(forKey: keys.keepScreenAwake) != nil {
                return storage.bool(forKey: keys.keepScreenAwake)
            }
            if let legacy = keys.legacyKeepScreenAwake, storage.object(forKey: legacy) != nil {
                return storage.bool(forKey: legacy)
            }
            return defaults.keepScreenAwake
        }
        set { write(newValue, keys.keepScreenAwake, \.keepScreenAwake) }
    }
    public var hdrDisplay: Bool {
        get { access(\.hdrDisplay); return read(keys.hdrDisplay, fallback: defaults.hdrDisplay) }
        set { write(newValue, keys.hdrDisplay, \.hdrDisplay) }
    }
    public var recordConfirmation: Bool {
        get { access(\.recordConfirmation); return read(keys.recordConfirmation, fallback: defaults.recordConfirmation) }
        set { write(newValue, keys.recordConfirmation, \.recordConfirmation) }
    }
    public var haptics: Bool {
        get { access(\.haptics); return read(keys.haptics, fallback: defaults.haptics) }
        set { write(newValue, keys.haptics, \.haptics) }
    }
    public var cacheOriginals: Bool {
        get { access(\.cacheOriginals); return read(keys.cacheOriginals, fallback: defaults.cacheOriginals) }
        set { write(newValue, keys.cacheOriginals, \.cacheOriginals) }
    }

    private func read(_ key: String, fallback: Bool) -> Bool {
        storage.object(forKey: key) == nil ? fallback : storage.bool(forKey: key)
    }

    private func access(_ keyPath: KeyPath<MonitorOperatorPreferences, Bool>) {
        if #available(macOS 14, *), let registrar = observation as? ObservationRegistrar {
            registrar.access(self, keyPath: keyPath)
        }
    }

    private func write(_ value: Bool, _ key: String, _ keyPath: KeyPath<MonitorOperatorPreferences, Bool>) {
        if #available(macOS 14, *), let registrar = observation as? ObservationRegistrar {
            registrar.withMutation(of: self, keyPath: keyPath) { storage.set(value, forKey: key) }
        } else {
            storage.set(value, forKey: key)
        }
    }
}

@available(macOS 14, *)
extension MonitorOperatorPreferences: Observable {}
