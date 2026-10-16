#if canImport(Metal)
    import Foundation
    import Observation
    import os

    /// The one persisted feed-upscaler choice (A2-78). Each app owns one instance under its own
    /// namespaced defaults key; the settings row observes ``upscaler`` and the renderer reads the
    /// same value off the main actor from its draw or decode callback.
    ///
    /// The value lives behind a lock rather than in a main-actor property mirrored into an unsafe
    /// static: the renderer runs whether or not settings were ever opened, so the stored choice is
    /// read once at construction and every reader, on any thread, sees the latest selection. The
    /// worst interleaving carries the old upscaler for one more frame.
    ///
    /// `@unchecked` only for `UserDefaults`, which Foundation documents as thread-safe but does not
    /// mark `Sendable`; every other stored property is immutable or lock-guarded.
    @available(macOS 14.0, *)
    public final class MonitorUpscalerPreference: Observable, @unchecked Sendable {
        /// The defaults key this app persists the choice under.
        public let storageKey: String
        private let defaults: UserDefaults
        private let onChange: @Sendable (MonitorUpscaler) -> Void
        private let selection: OSAllocatedUnfairLock<MonitorUpscaler>
        private let inputPreview = OSAllocatedUnfairLock(initialState: false)
        private let registrar = ObservationRegistrar()

        /// - Parameters:
        ///   - storageKey: the app's namespaced key, for example `OpenPocketCine.feedUpscaler`.
        ///   - defaults: where the choice persists.
        ///   - supported: maps the stored choice to one this device can run (the Fast floor when
        ///     nothing is stored or the device cannot run it).
        ///   - onChange: the app's diagnostics hook, called after every change with the new value.
        public init(
            storageKey: String,
            defaults: UserDefaults = .standard,
            supported: (MonitorUpscaler?) -> MonitorUpscaler = MonitorUpscaler.supported(or:),
            onChange: @escaping @Sendable (MonitorUpscaler) -> Void = { _ in }
        ) {
            self.storageKey = storageKey
            self.defaults = defaults
            self.onChange = onChange
            let stored = defaults.string(forKey: storageKey)
            let choice = stored.flatMap(Self.storedChoice)
            // A legacy title is rewritten once to today's raw value, so the stored key converges.
            if let stored, let choice, stored != choice.rawValue {
                defaults.set(choice.rawValue, forKey: storageKey)
            }
            selection = OSAllocatedUnfairLock(initialState: supported(choice))
        }

        /// The upscaler in effect. Observable for the settings row; safe to read from the renderer.
        /// Setting it persists the raw value and reports it through the diagnostics hook.
        public var upscaler: MonitorUpscaler {
            get {
                registrar.access(self, keyPath: \.upscaler)
                return selection.withLock { $0 }
            }
            set {
                registrar.withMutation(of: self, keyPath: \.upscaler) {
                    selection.withLock { $0 = newValue }
                }
                defaults.set(newValue.rawValue, forKey: storageKey)
                onChange(newValue)
            }
        }

        /// Debug: present the super-resolution model's input rather than its output. Not persisted.
        public var presentsSuperResolutionInput: Bool {
            get { inputPreview.withLock { $0 } }
            set { inputPreview.withLock { $0 = newValue } }
        }

        /// A persisted value this build still understands. The raw values are the stored strings and
        /// they were renamed to operator-facing words, so the old titles map forward instead of
        /// silently resetting an operator's choice to the default.
        public static func storedChoice(_ stored: String) -> MonitorUpscaler? {
            if let known = MonitorUpscaler(rawValue: stored) { return known }
            switch stored {
            case "Lanczos": return .lanczos
            case "MetalFX": return .spatial
            case "Super Res": return .superResolution
            default: return nil
            }
        }
    }
#endif
