#if os(iOS)
    import UIKit

    /// The light tap on an operator setting change, when haptics are on.
    public enum OperatorSettingsHaptics {
        @MainActor
        public static func selection(enabled: Bool) {
            guard enabled else { return }
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred()
        }
    }

    /// The operator's haptics setting, read when the control is touched. Each app passes its own
    /// preference; shared controls never store it.
    public struct OperatorHaptics: Sendable {
        public let isEnabled: @MainActor @Sendable () -> Bool

        public init(isEnabled: @escaping @MainActor @Sendable () -> Bool) {
            self.isEnabled = isEnabled
        }

        /// The light tap on a setting change.
        @MainActor public func selection() {
            OperatorSettingsHaptics.selection(enabled: isEnabled())
        }

        /// One light tap, for a passive heads-up the operator did not ask for.
        @MainActor public func light() {
            guard isEnabled() else { return }
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred()
        }

        /// The firm tap that confirms a panel placement.
        @MainActor public func confirm() {
            guard isEnabled() else { return }
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            generator.prepare()
            generator.impactOccurred(intensity: 1.0)
        }
    }
#endif
