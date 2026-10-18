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
        /// The remote shutter choice (A2-32). An app that offers no remote shutter names no key.
        public let remoteShutter: String?

        public init(
            keepScreenAwake: String, hdrDisplay: String, recordConfirmation: String,
            haptics: String, cacheOriginals: String, legacyKeepScreenAwake: String? = nil,
            remoteShutter: String? = nil
        ) {
            let keys = [keepScreenAwake, hdrDisplay, recordConfirmation, haptics, cacheOriginals]
                + (remoteShutter.map { [$0] } ?? [])
            precondition(keys.allSatisfy { !$0.isEmpty } && Set(keys).count == keys.count)
            self.keepScreenAwake = keepScreenAwake
            self.hdrDisplay = hdrDisplay
            self.recordConfirmation = recordConfirmation
            self.haptics = haptics
            self.cacheOriginals = cacheOriginals
            self.legacyKeepScreenAwake = legacyKeepScreenAwake
            self.remoteShutter = remoteShutter
        }
    }

    public struct Defaults: Sendable {
        public var keepScreenAwake: Bool
        public var hdrDisplay: Bool
        public var recordConfirmation: Bool
        public var haptics: Bool
        public var cacheOriginals: Bool
        /// On by default: volume and media presses record only while the live view is in front.
        public var remoteShutter: Bool

        public init(
            keepScreenAwake: Bool = true, hdrDisplay: Bool = false,
            recordConfirmation: Bool = true, haptics: Bool = true, cacheOriginals: Bool = true,
            remoteShutter: Bool = true
        ) {
            self.keepScreenAwake = keepScreenAwake
            self.hdrDisplay = hdrDisplay
            self.recordConfirmation = recordConfirmation
            self.haptics = haptics
            self.cacheOriginals = cacheOriginals
            self.remoteShutter = remoteShutter
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

    /// Whether volume and media presses toggle recording while the live view is in front (A2-32).
    /// Without a key (the app offers no remote shutter) this reads the default and stores nothing.
    public var remoteShutter: Bool {
        get {
            access(\.remoteShutter)
            return keys.remoteShutter.map { read($0, fallback: defaults.remoteShutter) } ?? defaults.remoteShutter
        }
        set {
            guard let key = keys.remoteShutter else { return }
            write(newValue, key, \.remoteShutter)
        }
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
