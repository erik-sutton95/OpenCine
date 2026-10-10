#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI

    /// Reference monitor `Peaking` operator options + long-press rows (`AssistQuickSettingsContent.peakingRows`).
    ///
    /// Reference monitor exposes exactly two peaking controls - there is no type / style / thickness picker:
    /// * Sensitivity - Low / Med / High (`Peaking.Sensitivity`)
    /// * Color - White / Blue / Red / Green (`Peaking.Color`)
    ///
    /// Defaults match `AssistConfiguration`: red, medium. The GPU compositor reads ``overlay(from:)``.
    public enum PeakingAssist {
        /// Reference monitor `peakingRows` Sensitivity help.
        public static let sensitivityHelp =
            "Higher sensitivity catches finer edges but can get noisy on detailed scenes."
        /// Reference monitor `peakingRows` Color help.
        public static let colorHelp =
            "Choose the edge color that stays readable over your typical scene."

        public typealias Color = MonitorPeakingColor
        public typealias Sensitivity = MonitorPeakingSense

        /// Reference monitor `SettingsPalette.peaking` order - White / Blue / Red / Green.
        public static let palette: [Color] = Color.allCases
        /// Segmented-control copy in `peakingRows`.
        public static let sensitivityOptions = Sensitivity.allCases.map(\.rawValue)

        public static func overlay(from options: MonitorPeakingOptions) -> MonitorPeakingOverlaySpec
        {
            options.overlay
        }

        public static func overlay(from effects: MonitorFrameEffects) -> MonitorPeakingOverlaySpec {
            MonitorPeakingOverlaySpec(
                color: effects.peakingColor, sensitivity: effects.peakingSensitivity)
        }

        public static func overlay(color: Color, sensitivity: Sensitivity)
            -> MonitorPeakingOverlaySpec
        {
            MonitorPeakingOverlaySpec(color: color, sensitivity: sensitivity)
        }

        /// Reference monitor `AssistQuickSettingsContent.peakingRows` - Sensitivity segmented + Color dots.
        @MainActor
        public static func longPressMenu<Palette: LiveChromePalette>(
            options: Binding<MonitorPeakingOptions>, palette _: Palette.Type,
            haptics: OperatorHaptics, compact: Bool = false
        ) -> PeakingLongPressMenu<Palette> {
            PeakingLongPressMenu(options: options, haptics: haptics, compact: compact)
        }

        /// Binds ``MonitorAssistState`` color / sensitivity and persists on change.
        @MainActor
        public static func longPressMenu<Looks: MonitorLookProvider, Palette: LiveChromePalette>(
            assist: MonitorAssistState<Looks>, palette: Palette.Type, haptics: OperatorHaptics,
            compact: Bool = false
        ) -> PeakingLongPressMenu<Palette> {
            longPressMenu(
                options: Binding(
                    get: { assist.peakingOptions },
                    set: {
                        assist.peakingOptions = $0
                        assist.persist()
                    }
                ),
                palette: palette, haptics: haptics, compact: compact
            )
        }

        /// Reference monitor `peakingRows` Sensitivity tap - same-value is a no-op (`SettingsSegmented`).
        @MainActor
        public static func selectSensitivity<Looks: MonitorLookProvider>(
            _ raw: String, assist: MonitorAssistState<Looks>
        ) {
            guard let level = Sensitivity(rawValue: raw),
                level != assist.peakingSensitivity
            else { return }
            assist.peakingSensitivity = level
            assist.persist()
        }

        /// Reference monitor `peakingRows` Color tap - same-value is a no-op (`SettingsColorDots`).
        @MainActor
        public static func selectColor<Looks: MonitorLookProvider>(
            _ raw: String, assist: MonitorAssistState<Looks>
        ) {
            guard let color = Color(rawValue: raw),
                color != assist.peakingColor
            else { return }
            assist.peakingColor = color
            assist.persist()
        }

        /// Reference monitor `resetPeaking` - red / medium.
        @MainActor
        public static func reset<Looks: MonitorLookProvider>(_ assist: MonitorAssistState<Looks>) {
            assist.peakingOptions = .default
            assist.persist()
        }
    }

    extension MonitorFrameEffects {
        public var peakingOptions: MonitorPeakingOptions {
            get { MonitorPeakingOptions(color: peakingColor, sensitivity: peakingSensitivity) }
            set {
                peakingColor = newValue.color
                peakingSensitivity = newValue.sensitivity
            }
        }
    }

    extension MonitorAssistState {
        public var peakingOptions: MonitorPeakingOptions {
            get { MonitorPeakingOptions(color: peakingColor, sensitivity: peakingSensitivity) }
            set {
                peakingColor = newValue.color
                peakingSensitivity = newValue.sensitivity
            }
        }
    }

    public struct PeakingLongPressMenu<Palette: LiveChromePalette>: View {
        @Binding public var options: MonitorPeakingOptions
        public var haptics: OperatorHaptics
        public var compact: Bool = false

        public init(
            options: Binding<MonitorPeakingOptions>, haptics: OperatorHaptics, compact: Bool = false
        ) {
            _options = options
            self.haptics = haptics
            self.compact = compact
        }

        public var body: some View { assistMenu }

        public var assistMenu: MonitorPeakingMenu {
            MonitorPeakingMenu(
                options: $options,
                colors: PeakingAssist.palette.map {
                    .init(value: $0, title: $0.rawValue, color: $0.swatch(Palette.self))
                }, sensitivityHelp: PeakingAssist.sensitivityHelp,
                colorHelp: PeakingAssist.colorHelp,
                compact: compact, feedback: { haptics.selection() })
        }
    }

    // Display swatches follow the app's HDR theme; detector RGB stays portable.
    extension MonitorPeakingColor {
        public func swatch<Palette: LiveChromePalette>(_: Palette.Type) -> SwiftUI.Color {
            switch self {
            case .white: Palette.text
            case .blue: Palette.chromeColor(red: 64.0 / 255, green: 142.0 / 255, blue: 1)
            case .red: Palette.rec
            case .green: Palette.good
            }
        }
    }
#endif
