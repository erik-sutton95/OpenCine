#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI

    /// Reference monitor `AssistConfiguration.Zebra` + long-press rows (`AssistQuickSettingsContent.zebraRows`).
    ///
    /// Reference monitor exposes exactly these operator controls - there is no fill-vs-stripe / pattern picker
    /// (stripes always paint the zone colour) and no extra bands beyond dual zebra:
    /// * Units - 0-255 / IRE (`Zebra.Unit`; stored thresholds stay on the 0–100 monitoring axis)
    /// * Highlight - enable, threshold, fill colour White / Amber / Red
    /// * Midtone - enable, threshold, fill colour Amber / Cyan / Green
    ///
    /// Defaults follow `AssistConfiguration.Zebra` (IRE, white / amber, midtone 55) except highlight:
    /// 99, one IRE under the live-tap ceiling so the typical D-Log2 243–247 shelf paints (#136).
    /// The GPU compositor reads ``overlay(from:)``.
    public enum ZebraAssist {
        /// Reference monitor `zebraRows` / `SettingsSegmented` labels.
        public static let unitOptions = ["0-255", "IRE"]
        public static let unitsTitle = "Units"
        public static let unitsHelp =
            "Switch between native 0-255 encoded codes and a 0-100 monitoring IRE scale."
        public static let highlightTitle = "Highlight"
        public static let highlightHelp =
            "High zebra warns when bright detail approaches clipping after the active log curve is compensated."
        public static let midtoneTitle = "Midtone"
        public static let midtoneHelp =
            "Midtone zebra gives a curve-compensated reference band for faces or key subject exposure."

        /// Reference monitor `ImageEffectsCompositor.blendStripedZebra` - `CIStripesGenerator`.
        public enum StripeLook {
            public static let width: CGFloat = 5
            public static let sharpness: CGFloat = 1
            public static let rotation: CGFloat = .pi / 4
        }

        /// Reference monitor `AssistConfiguration.Zebra.Unit`. Editor labels are `0-255` / `IRE`.
        public enum Unit: String, CaseIterable, Codable, Sendable, Identifiable {
            case native = "Native"
            case ire = "IRE"

            public var id: String { rawValue }

            /// Segmented-control copy in `zebraRows`.
            public var editorLabel: String {
                switch self {
                case .native: "0-255"
                case .ire: "IRE"
                }
            }

            public static func fromEditorLabel(_ label: String) -> Unit {
                label == "0-255" ? .native : .ire
            }
        }

        /// Reference monitor `AssistConfiguration.Zebra.StripeColor` - GPU fill lives on ``MonitorZebraPaint``.
        public typealias StripeColor = MonitorZebraPaint

        /// Reference monitor `SettingsPalette.highlight`.
        public static let highlightPalette: [StripeColor] = [.white, .amber, .red]
        /// Reference monitor `SettingsPalette.midtone`.
        public static let midtonePalette: [StripeColor] = [.amber, .cyan, .green]

        public struct Options: Equatable, Codable, Sendable {
            public var unit: Unit
            public var highlightEnabled: Bool
            public var highlightIRE: Double
            public var highlightColor: StripeColor
            public var midtoneEnabled: Bool
            public var midtoneIRE: Double
            public var midtoneColor: StripeColor

            public static let `default` = Options(
                unit: .ire,
                highlightEnabled: true,
                highlightIRE: LiveZebra.highlightIRE,
                highlightColor: .white,
                midtoneEnabled: true,
                midtoneIRE: LiveZebra.midtoneIRE,
                midtoneColor: .amber
            )

            public init(
                unit: Unit = .ire,
                highlightEnabled: Bool = true,
                highlightIRE: Double = LiveZebra.highlightIRE,
                highlightColor: StripeColor = .white,
                midtoneEnabled: Bool = true,
                midtoneIRE: Double = LiveZebra.midtoneIRE,
                midtoneColor: StripeColor = .amber
            ) {
                self.unit = unit
                self.highlightEnabled = highlightEnabled
                self.highlightIRE = highlightIRE
                self.highlightColor = highlightColor
                self.midtoneEnabled = midtoneEnabled
                self.midtoneIRE = midtoneIRE
                self.midtoneColor = midtoneColor
            }

            public var overlay: OverlaySpec {
                OverlaySpec(
                    highlightEnabled: highlightEnabled,
                    highlightIRE: highlightIRE,
                    highlightColor: highlightColor,
                    midtoneEnabled: midtoneEnabled,
                    midtoneIRE: midtoneIRE,
                    midtoneColor: midtoneColor
                )
            }

            /// Operator-facing threshold, honouring ``unit`` (the reference monitor `Zebra.displayValue`).
            /// `clipByte` is the monitored source's live ceiling for `transfer`.
            public func displayValue(for ire: Double, transfer: MonitorTransfer, clipByte: Int)
                -> Int
            {
                switch unit {
                case .ire: Int(ire.rounded())
                case .native:
                    Int(
                        (ScopeDisplayScale.signalNative(
                            monitorPercent: ire, transfer: transfer, clipByte: clipByte) * 255)
                            .rounded())
                }
            }

            public mutating func setHighlight(
                fromDisplay value: Int, transfer: MonitorTransfer, clipByte: Int
            ) {
                highlightIRE = Self.ire(
                    fromDisplay: value, unit: unit, transfer: transfer, clipByte: clipByte)
            }

            public mutating func setMidtone(
                fromDisplay value: Int, transfer: MonitorTransfer, clipByte: Int
            ) {
                midtoneIRE = Self.ire(
                    fromDisplay: value, unit: unit, transfer: transfer, clipByte: clipByte)
            }

            public var editorMaximum: Int { unit == .native ? 255 : 100 }

            public static func ire(
                fromDisplay value: Int, unit: Unit, transfer: MonitorTransfer, clipByte: Int
            ) -> Double {
                switch unit {
                case .ire:
                    min(100, max(0, Double(value)))
                case .native:
                    ScopeDisplayScale.monitorPercent(
                        Double(min(max(value, 0), 255)) / 255,
                        transfer: transfer, clipByte: clipByte)
                }
            }
        }

        /// Zone flags + IRE + stripe fill the GPU zebra pass reads (the reference monitor `ZebraSettings` minus unit).
        /// Unit is editor-only - stored thresholds stay on the 0–100 monitoring axis.
        public struct OverlaySpec: Equatable, Sendable {
            public var highlightEnabled: Bool
            public var highlightIRE: Double
            public var highlightColor: StripeColor
            public var midtoneEnabled: Bool
            public var midtoneIRE: Double
            public var midtoneColor: StripeColor

            public init(
                highlightEnabled: Bool, highlightIRE: Double, highlightColor: StripeColor,
                midtoneEnabled: Bool, midtoneIRE: Double, midtoneColor: StripeColor
            ) {
                self.highlightEnabled = highlightEnabled
                self.highlightIRE = highlightIRE
                self.highlightColor = highlightColor
                self.midtoneEnabled = midtoneEnabled
                self.midtoneIRE = midtoneIRE
                self.midtoneColor = midtoneColor
            }
        }

        public static func overlay(from options: Options) -> OverlaySpec { options.overlay }

        public static func overlay(from effects: MonitorFrameEffects) -> OverlaySpec {
            OverlaySpec(
                highlightEnabled: effects.zebraHighlight,
                highlightIRE: effects.zebraHighlightIRE,
                highlightColor: effects.zebraHighlightColor,
                midtoneEnabled: effects.zebraMidtone,
                midtoneIRE: effects.zebraMidtoneIRE,
                midtoneColor: effects.zebraMidtoneColor
            )
        }

        /// Reference monitor `AssistQuickSettingsContent.zebraRows`. `clipByte` is the monitored
        /// source's live ceiling for `transfer`.
        @MainActor
        public static func longPressMenu<Palette: LiveChromePalette>(
            options: Binding<Options>, palette _: Palette.Type, haptics: OperatorHaptics,
            transfer: MonitorTransfer, clipByte: Int, compact: Bool = false
        ) -> ZebraLongPressMenu<Palette> {
            ZebraLongPressMenu(
                options: options, haptics: haptics, transfer: transfer, clipByte: clipByte,
                compact: compact)
        }

        /// Binds ``MonitorAssistState`` dual-zebra options and persists on change.
        @MainActor
        public static func longPressMenu<Looks: MonitorLookProvider, Palette: LiveChromePalette>(
            assist: MonitorAssistState<Looks>, stores: AssistPanelStores, palette: Palette.Type,
            haptics: OperatorHaptics, transfer: MonitorTransfer, clipByte: Int,
            compact: Bool = false
        ) -> ZebraLongPressMenu<Palette> {
            longPressMenu(
                options: Binding(
                    get: { assist.zebraOptions(stores: stores) },
                    set: {
                        assist.setZebraOptions($0, stores: stores)
                        assist.persist()
                    }
                ),
                palette: palette, haptics: haptics, transfer: transfer, clipByte: clipByte,
                compact: compact
            )
        }
    }

    extension MonitorZebraPaint {
        /// Reference monitor `SettingsPalette` token (not overlay RGB).
        public func swatch<Palette: LiveChromePalette>(_: Palette.Type) -> Color {
            switch self {
            case .white: Palette.text
            case .amber: Palette.amber
            case .red: Palette.rec
            case .cyan: Palette.chromeColor(red: 0, green: 0.85, blue: 0.9)
            case .green: Palette.good
            }
        }
    }

    extension MonitorFrameEffects {
        public var zebraOptions: ZebraAssist.Options {
            get {
                ZebraAssist.Options(
                    highlightEnabled: zebraHighlight,
                    highlightIRE: zebraHighlightIRE,
                    highlightColor: zebraHighlightColor,
                    midtoneEnabled: zebraMidtone,
                    midtoneIRE: zebraMidtoneIRE,
                    midtoneColor: zebraMidtoneColor
                )
            }
            set {
                zebraHighlight = newValue.highlightEnabled
                zebraHighlightIRE = newValue.highlightIRE
                zebraHighlightColor = newValue.highlightColor
                zebraMidtone = newValue.midtoneEnabled
                zebraMidtoneIRE = newValue.midtoneIRE
                zebraMidtoneColor = newValue.midtoneColor
            }
        }
    }

    extension MonitorAssistState {
        /// Dual-zebra options with the editor's unit, which is saved beside the assist snapshot.
        public func zebraOptions(stores: AssistPanelStores) -> ZebraAssist.Options {
            ZebraAssist.Options(
                unit: stores.zebraUnit,
                highlightEnabled: zebraHighlight,
                highlightIRE: zebraHighlightIRE,
                highlightColor: zebraHighlightColor,
                midtoneEnabled: zebraMidtone,
                midtoneIRE: zebraMidtoneIRE,
                midtoneColor: zebraMidtoneColor
            )
        }

        public func setZebraOptions(_ options: ZebraAssist.Options, stores: AssistPanelStores) {
            stores.zebraUnit = options.unit
            zebraHighlight = options.highlightEnabled
            zebraHighlightIRE = options.highlightIRE
            zebraHighlightColor = options.highlightColor
            zebraMidtone = options.midtoneEnabled
            zebraMidtoneIRE = options.midtoneIRE
            zebraMidtoneColor = options.midtoneColor
        }
    }

    public struct ZebraLongPressMenu<Palette: LiveChromePalette>: View {
        @Binding public var options: ZebraAssist.Options
        public var haptics: OperatorHaptics
        public var transfer: MonitorTransfer
        /// The monitored source's own live ceiling (STATE-01: never a process-wide one).
        public var clipByte: Int
        public var compact: Bool = false

        public init(
            options: Binding<ZebraAssist.Options>, haptics: OperatorHaptics,
            transfer: MonitorTransfer, clipByte: Int, compact: Bool = false
        ) {
            _options = options
            self.haptics = haptics
            self.transfer = transfer
            self.clipByte = clipByte
            self.compact = compact
        }

        public var body: some View { assistMenu(transfer: transfer, clipByte: clipByte) }

        public func assistMenu(transfer: MonitorTransfer, clipByte: Int) -> MonitorZebraMenu<
            ZebraAssist.Unit, ZebraAssist.StripeColor
        > {
            MonitorZebraMenu(
                units: ZebraAssist.Unit.allCases, unit: $options.unit, title: { $0.editorLabel },
                unitsTitle: ZebraAssist.unitsTitle, unitsHelp: ZebraAssist.unitsHelp,
                highlightHelp: ZebraAssist.highlightHelp, midtoneHelp: ZebraAssist.midtoneHelp,
                highlight: zone(
                    enabled: $options.highlightEnabled, threshold: $options.highlightIRE,
                    colors: ZebraAssist.highlightPalette, paint: $options.highlightColor,
                    transfer: transfer, clipByte: clipByte),
                midtone: zone(
                    enabled: $options.midtoneEnabled, threshold: $options.midtoneIRE,
                    colors: ZebraAssist.midtonePalette, paint: $options.midtoneColor,
                    transfer: transfer, clipByte: clipByte), compact: compact,
                selectionFeedback: { haptics.selection() },
                toggleFeedback: {
                    haptics.selection()
                    haptics.selection()
                })
        }
        private func zone(
            enabled: Binding<Bool>, threshold: Binding<Double>, colors: [ZebraAssist.StripeColor],
            paint: Binding<ZebraAssist.StripeColor>, transfer: MonitorTransfer, clipByte: Int
        ) -> MonitorZebraZone<ZebraAssist.StripeColor> {
            MonitorZebraZone(
                enabled: enabled,
                threshold: Binding(
                    get: { threshold.wrappedValue },
                    set: {
                        threshold.wrappedValue = min(100, max(0, $0))
                    }),
                displayValue: options.displayValue(
                    for: threshold.wrappedValue, transfer: transfer, clipByte: clipByte),
                colors: colors.map {
                    .init(value: $0, title: $0.rawValue, color: $0.swatch(Palette.self))
                },
                paint: paint)
        }
    }
#endif
