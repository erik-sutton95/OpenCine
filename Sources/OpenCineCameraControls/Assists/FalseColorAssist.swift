#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI

    /// The app's side of false colour: the scale help naming its curves, and each curve's official
    /// Rec.709 look. A host value, so each integration's looks stay its own.
    public struct FalseColorLooks: Sendable {
        /// Reference monitor Scale help, the app's curves in the first sentence.
        public let scaleHelp: String
        /// Grey axis (33 points) of the curve's official Rec.709 look; nil stays on the signal.
        public let rec709LookCurve: @Sendable (MonitorTransfer) -> [Double]?

        public init(
            scaleHelp: String, rec709LookCurve: @escaping @Sendable (MonitorTransfer) -> [Double]?
        ) {
            self.scaleHelp = scaleHelp
            self.rec709LookCurve = rec709LookCurve
        }

        /// True when the 709 reading applies: the operator picked 709 and this curve has an
        /// official Rec.709 look.
        public func readsThroughLook(transfer: MonitorTransfer, rec709: Bool) -> Bool {
            LiveColorScience.readsThroughLook(lookCurve: rec709LookCurve(transfer), rec709: rec709)
        }

        /// `LiveColorScience.falseColorClip` through the official look, for a source whose live
        /// ceiling for `transfer` is `clipByte`.
        public func falseColorClip(
            scale: LiveFalseColorScale, transfer: MonitorTransfer, rec709: Bool, clipByte: Int
        ) -> (transfer: MonitorTransfer, ceiling: Double) {
            LiveColorScience.falseColorClip(
                scale: scale, transfer: transfer, rec709: rec709,
                lookCurve: rec709LookCurve(transfer), clipEncoded: Double(clipByte) / 255)
        }
    }

    /// Reference monitor `AssistQuickSettingsContent.falseColorRows` + `FalseColorReference`.
    ///
    /// Long-press options:
    /// * Scale: CineStop / Video / IRE / Limits
    /// * Reference Display - compact color key over live view; turning it on arms False Color
    public enum FalseColorAssist {
        /// LOG / 709 row: how Video and IRE read log curves.
        public static let readOptions = ["LOG", "709"]
        public static let readHelp =
            "How false color reads log footage. 709 reads the camera's official Rec.709 look, "
            + "the way RED, ARRI and most monitors apply false color, so clip means clipped in "
            + "the Rec.709 image. LOG reads the raw signal like WAVE, with the full highlight "
            + "range and the camera's own clip."

        /// Reference monitor `falseColorRows` Reference Display help.
        public static let referenceHelp =
            "Show a compact color key over live view while False Color is active."

        /// Reference monitor `AssistQuickSettingsContent` Scale segments.
        public static let scaleOptions = ["CineStop", "Video", "IRE", "Limits"]

        public struct Options: Equatable, Codable, Sendable {
            public var scale: MonitorFalseColorSelection
            public var referenceEnabled: Bool

            public init(
                scale: MonitorFalseColorSelection, referenceEnabled: Bool
            ) {
                self.scale = scale
                self.referenceEnabled = referenceEnabled
            }

            public static let `default` = Options(scale: .sceneStops, referenceEnabled: true)
        }

        public static func scale(forMenuLabel label: String) -> MonitorFalseColorSelection {
            switch label {
            case "Video", "PStops", "ZC Stops": .stops
            case "IRE": .ire
            case "Limits": .limits
            default: .sceneStops
            }
        }

        /// Reference monitor `falseColorScaleLabel`.
        public static func menuLabel(for scale: MonitorFalseColorSelection) -> String {
            scale.referenceScaleLabel
        }

        /// WAVE-axis legend copy. CineStop labels come from core (see `legendStops`).
        public static func legendLabels(scale: MonitorFalseColorSelection) -> [String] {
            switch scale {
            case .sceneStops:
                []
            case .stops:
                [
                    "0–4", "5", "10–12", "41–48", "61–70", "92–93", "94–95",
                    "96–98", "99–100",
                ]
            case .ire:
                ["BDL", "NBDL", "18%MG", "MG+1", "80%WC", "95%WC"]
            case .limits:
                ["0–4", "5–9", "94–98", "99–100"]
            }
        }

        /// Reference monitor `AssistQuickSettingsContent.falseColorRows`.
        @MainActor
        public static func longPressMenu(
            options: Binding<Options>,
            looks: FalseColorLooks,
            haptics: OperatorHaptics,
            compact: Bool = false,
            transfer: MonitorTransfer = .rec709,
            clipByte: Int,
            rec709: Binding<Bool>? = nil,
            referenceDisplayAvailable: Bool = true,
            onReferenceEnabled: (() -> Void)? = nil
        ) -> FalseColorLongPressMenu {
            FalseColorLongPressMenu(
                options: options,
                looks: looks,
                haptics: haptics,
                compact: compact,
                transfer: transfer,
                clipByte: clipByte,
                rec709: rec709,
                referenceDisplayAvailable: referenceDisplayAvailable,
                onReferenceEnabled: onReferenceEnabled
            )
        }

        @MainActor
        public static func commonMenu<Looks: MonitorLookProvider>(
            assist: MonitorAssistState<Looks>, looks: FalseColorLooks, haptics: OperatorHaptics,
            compact: Bool = false, transfer: MonitorTransfer, clipByte: Int, referenceDisplayAvailable: Bool = true
        ) -> MonitorFalseColorMenu<MonitorFalseColorSelection> {
            longPressMenu(
                options: Binding(
                    get: { assist.falseColorOptions },
                    set: {
                        assist.falseColorOptions = $0
                        assist.persist()
                    }), looks: looks, haptics: haptics, compact: compact, transfer: transfer,
                clipByte: clipByte,
                rec709: Binding(
                    get: { assist.falseColorRec709 },
                    set: {
                        assist.falseColorRec709 = $0
                        assist.persist()
                    }), referenceDisplayAvailable: referenceDisplayAvailable, onReferenceEnabled: { assist.falseColor = true }
            ).commonMenu
        }

        /// Reference monitor `FalseColorReference` - 264×52 glass ruler with sparse zone chips.
        @MainActor
        public static func referenceDisplay(
            scale: MonitorFalseColorSelection, colorMode: ColorMode = .normal, rec709: Bool,
            clipByte: Int, looks: FalseColorLooks
        ) -> FalseColorReference {
            FalseColorReference(
                scale: scale, colorMode: colorMode, rec709: rec709, clipByte: clipByte, looks: looks
            )
        }

        /// the reference monitor: turning Reference Display on also arms False Color.
        @MainActor
        public static func toggleReference<Looks: MonitorLookProvider>(
            assist: MonitorAssistState<Looks>
        ) {
            assist.falseColorReference.toggle()
            if assist.falseColorReference {
                assist.falseColor = true
            }
            assist.persist()
        }
    }

    extension MonitorAssistState {
        public var falseColorOptions: FalseColorAssist.Options {
            get {
                FalseColorAssist.Options(
                    scale: falseColorScale, referenceEnabled: falseColorReference)
            }
            set {
                falseColorScale = newValue.scale
                falseColorReference = newValue.referenceEnabled
            }
        }
    }

    extension MonitorFrameEffects {
        public var falseColorOptions: FalseColorAssist.Options {
            get {
                FalseColorAssist.Options(scale: falseColorScale, referenceEnabled: false)
            }
            set { falseColorScale = newValue.scale }
        }
    }

    // MARK: - Long-press rows

    public struct FalseColorLongPressMenu: View {
        @Binding public var options: FalseColorAssist.Options
        public var looks: FalseColorLooks
        public var haptics: OperatorHaptics
        public var compact: Bool = false
        public var transfer: MonitorTransfer = .rec709
        /// The monitored source's live ceiling for `transfer`.
        public var clipByte: Int
        public var rec709: Binding<Bool>? = nil
        public var referenceDisplayAvailable: Bool = true
        public var onReferenceEnabled: (() -> Void)? = nil

        public init(
            options: Binding<FalseColorAssist.Options>, looks: FalseColorLooks,
            haptics: OperatorHaptics, compact: Bool = false, transfer: MonitorTransfer = .rec709,
            clipByte: Int, rec709: Binding<Bool>? = nil, referenceDisplayAvailable: Bool = true,
            onReferenceEnabled: (() -> Void)? = nil
        ) {
            _options = options
            self.looks = looks
            self.haptics = haptics
            self.compact = compact
            self.transfer = transfer
            self.clipByte = clipByte
            self.rec709 = rec709
            self.referenceDisplayAvailable = referenceDisplayAvailable
            self.onReferenceEnabled = onReferenceEnabled
        }

        public var body: some View { commonMenu }

        public var commonMenu: MonitorFalseColorMenu<MonitorFalseColorSelection> {
            MonitorFalseColorMenu(
                scales: FalseColorAssist.scaleOptions.map(FalseColorAssist.scale(forMenuLabel:)),
                scale: $options.scale, referenceEnabled: $options.referenceEnabled, read709: rec709,
                reference: FalseColorReference(
                    scale: options.scale, transfer: transfer, inspector: true,
                    rec709: rec709?.wrappedValue ?? false, clipByte: clipByte, looks: looks
                ).displayValues,
                title: FalseColorAssist.menuLabel(for:), scaleHelp: looks.scaleHelp,
                readHelp: FalseColorAssist.readHelp, referenceHelp: FalseColorAssist.referenceHelp,
                compact: compact, referenceDisplayAvailable: referenceDisplayAvailable,
                selectionFeedback: { haptics.selection() },
                readFeedback: {
                    haptics.selection()
                    haptics.selection()
                },
                referenceFeedback: {
                    haptics.selection()
                    haptics.selection()
                }, onReferenceEnabled: { onReferenceEnabled?() })
        }
    }

    // MARK: - On-feed reference ruler (the reference monitor `FalseColorReference`)

    /// Reference monitor `FalseColorReference` - 264×52 glass ruler with proportional zone chips.
    public struct FalseColorReference: View {
        public struct Segment: Equatable, Identifiable {
            public let id: Int
            public let lowerFraction: Double
            public let upperFraction: Double
            public let band: LiveFalseColorBand

            public init(
                id: Int, lowerFraction: Double, upperFraction: Double, band: LiveFalseColorBand
            ) {
                self.id = id
                self.lowerFraction = lowerFraction
                self.upperFraction = upperFraction
                self.band = band
            }
        }

        public struct AxisMarker: Equatable, Identifiable {
            public let id: Int
            public let label: String
            public let fraction: Double

            public init(
                id: Int, label: String, fraction: Double
            ) {
                self.id = id
                self.label = label
                self.fraction = fraction
            }
        }

        public static let panelSize = MonitorFalseColorReference.panelSize

        public var scale: MonitorFalseColorSelection
        public var transfer: MonitorTransfer
        /// Read: 709 / LOG. A view input so flipping it redraws the key.
        public var rec709: Bool
        /// The monitored source's live ceiling for `transfer` (STATE-01: per source).
        public var clipByte: Int
        public var looks: FalseColorLooks

        public init(
            scale: MonitorFalseColorSelection, colorMode: ColorMode = .normal, rec709: Bool,
            clipByte: Int, looks: FalseColorLooks
        ) {
            self.scale = scale
            self.transfer = MonitorTransfer(colorMode)
            self.rec709 = rec709
            self.clipByte = clipByte
            self.looks = looks
        }

        public init(
            scale: MonitorFalseColorSelection, transfer: MonitorTransfer, inspector: Bool = false,
            rec709: Bool, clipByte: Int, looks: FalseColorLooks
        ) {
            self.scale = scale
            self.transfer = transfer
            self.inspector = inspector
            self.rec709 = rec709
            self.clipByte = clipByte
            self.looks = looks
        }

        /// Reference monitor `FalseColorReference.curveKeyLabel` - camera transfers, compact keys.
        public static func curveKeyLabel(_ transfer: MonitorTransfer) -> String {
            switch transfer {
            case .rec709: "709"
            case .hdr: "HLG"
            case .dlog: "D-Log"
            case .dlogm: "DLM ≈"
            case .dlog2: "D-Log2"
            case .ilog: "I-Log"
            case .srgb: "sRGB"
            case .nlog: "N-Log"
            case .log3G10: "L3G10"
            }
        }

        /// Reference monitor `FalseColorReference.axisLabels`.
        public static func axisLabels(scale: MonitorFalseColorSelection) -> [String] {
            switch scale {
            case .sceneStops: []
            case .stops, .ire: ["crush", "18%", "skin", "clip"]
            case .limits: ["crushed", "midtones untouched", "clipped"]
            }
        }

        public var inspector = false

        public var body: some View {
            MonitorFalseColorReference(values: displayValues, inspector: inspector)
        }

        public var displayValues: MonitorFalseColorReferenceValues {
            MonitorFalseColorReferenceValues(
                subtitle:
                    "\(scale.referenceScaleLabel) · \(Self.curveKeyLabel(looks.readsThroughLook(transfer: transfer, rec709: rec709) ? .rec709 : transfer))",
                segments: Self.segments(
                    scale: scale, transfer: transfer, rec709: rec709, clipByte: clipByte,
                    looks: looks
                ).map {
                    MonitorFalseColorReferenceSegment(
                        id: $0.id, lowerFraction: $0.lowerFraction,
                        upperFraction: $0.upperFraction, red: $0.band.red, green: $0.band.green,
                        blue: $0.band.blue)
                },
                markers: scale.liveScale.usesSceneStops
                    ? Self.sceneStopMarkers(
                        transfer: transfer, rec709: rec709, clipByte: clipByte, looks: looks
                    ).map {
                        MonitorFalseColorReferenceMarker(
                            id: $0.id, label: $0.label, fraction: $0.fraction)
                    } : [],
                axisLabels: Self.axisLabels(scale: scale))
        }

        public static func segments(
            scale: MonitorFalseColorSelection, transfer: MonitorTransfer, rec709: Bool,
            clipByte: Int,
            looks: FalseColorLooks
        ) -> [Segment] {
            let clip = looks.falseColorClip(
                scale: scale.liveScale, transfer: transfer, rec709: rec709, clipByte: clipByte)
            return LiveColorScience.falseColorBands(
                scale.liveScale, transfer: clip.transfer, clipEncoded: clip.ceiling
            ).enumerated().map {
                index, band in
                Segment(
                    id: index,
                    lowerFraction: fraction(
                        band.lowerBound, scale: scale, transfer: transfer, rec709: rec709,
                        clipByte: clipByte, looks: looks, infiniteFallback: 0),
                    upperFraction: fraction(
                        band.upperBound, scale: scale, transfer: transfer, rec709: rec709,
                        clipByte: clipByte, looks: looks, infiniteFallback: 1),
                    band: band)
            }
        }

        /// Scene stops at this curve's clip shelf, where CineStop's clip band starts.
        public static func sceneStopClip(
            transfer: MonitorTransfer, rec709: Bool, clipByte: Int,
            looks: FalseColorLooks
        ) -> Double {
            let clip = looks.falseColorClip(
                scale: .sceneStops, transfer: transfer, rec709: rec709, clipByte: clipByte)
            let ceiling = LiveColorScience.stops(
                encoded: LiveColorScience.clipShelf(ceiling: clip.ceiling), transfer: clip.transfer)
            return ceiling.isFinite ? ceiling : LiveColorScience.sceneStopDefaultClip
        }

        /// CineStop ruler span in scene stops: crush on the left, one stop past this
        /// curve's clip on the right, so every stop the camera records gets room.
        public static func sceneStopDomain(
            transfer: MonitorTransfer, rec709: Bool, clipByte: Int,
            looks: FalseColorLooks
        ) -> ClosedRange<Double> {
            -8.5...(max(
                2.5,
                sceneStopClip(transfer: transfer, rec709: rec709, clipByte: clipByte, looks: looks))
                + 1)
        }

        /// CineStop axis: every second stop from −6, stopping 1½ stops short of this
        /// curve's clip so no label collides with the clip mark, then clip.
        public static func sceneStopMarkers(
            transfer: MonitorTransfer, rec709: Bool, clipByte: Int,
            looks: FalseColorLooks
        ) -> [AxisMarker] {
            let clip = sceneStopClip(
                transfer: transfer, rec709: rec709, clipByte: clipByte, looks: looks)
            var marks: [(String, Double)] = []
            for stop in stride(from: -6, to: clip - 1.5, by: 2) {
                marks.append((stopLabel(Int(stop)), stop))
            }
            marks.append(("clip", clip))
            return marks.enumerated().map { index, mark in
                AxisMarker(
                    id: index, label: mark.0,
                    fraction: fraction(
                        mark.1, scale: .sceneStops, transfer: transfer, rec709: rec709,
                        clipByte: clipByte, looks: looks, infiniteFallback: 1))
            }
        }

        private static func stopLabel(_ stop: Int) -> String {
            if stop == 0 { return "18%" }
            return stop < 0 ? "−\(-stop)" : "+\(stop)"
        }

        private static func fraction(
            _ value: Double, scale: MonitorFalseColorSelection, transfer: MonitorTransfer,
            rec709: Bool, clipByte: Int, looks: FalseColorLooks, infiniteFallback: Double
        ) -> Double {
            guard value.isFinite else { return infiniteFallback }
            guard scale.liveScale.usesSceneStops else { return min(1, max(0, value / 100)) }
            let domain = sceneStopDomain(
                transfer: transfer, rec709: rec709, clipByte: clipByte, looks: looks)
            return min(
                1, max(0, (value - domain.lowerBound) / (domain.upperBound - domain.lowerBound)))
        }

    }
    extension MonitorFalseColorSelection {
        /// Reference monitor `FalseColorReference.scaleLabel`.
        public var referenceScaleLabel: String {
            switch self {
            case .sceneStops: "CineStop"
            case .stops: "Video"
            case .ire: "IRE"
            case .limits: "Limits"
            }
        }
    }
#endif
