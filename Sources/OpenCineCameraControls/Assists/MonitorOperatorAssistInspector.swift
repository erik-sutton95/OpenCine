#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineMedia
import SwiftUI
import UIKit

/// Source-calibrated exposure menus. Common navigation, help and inspector lifetime stay shared.
public struct MonitorOperatorSignalOptions {
    public let falseColor: AnyView?
    public let zebra: AnyView?
    public let reference: MonitorFalseColorReferenceValues?
    public let referenceAvailable: Bool?
    public let level: AnyView?
    public let instantReview: AnyView?
    public let resetFalseColor: (() -> Void)?
    public let resetZebra: (() -> Void)?
    public init(falseColor: AnyView? = nil, zebra: AnyView? = nil,
        reference: MonitorFalseColorReferenceValues? = nil, referenceAvailable: Bool? = nil,
        level: AnyView? = nil, instantReview: AnyView? = nil,
        resetFalseColor: (() -> Void)? = nil, resetZebra: (() -> Void)? = nil) {
        self.falseColor = falseColor; self.zebra = zebra; self.reference = reference
        self.referenceAvailable = referenceAvailable
        self.level = level; self.instantReview = instantReview
        self.resetFalseColor = resetFalseColor; self.resetZebra = resetZebra
    }

    /// The source supplies options for a tool that has no shared ones (level, instant review),
    /// so its palette chip opens the inspector (A1-23).
    public func offers(_ tool: MonitorAssistSelection) -> Bool {
        switch tool {
        case .level: level != nil
        case .instantReview: instantReview != nil
        default: false
        }
    }
}

/// Common tool selection, menus, help and comparison controls around one bounded native preview.
public struct MonitorOperatorAssistInspector<Looks: MonitorLookProvider, Palette: LiveChromePalette,
    Preview: View, LookMenu: View>: View {
    private let tool: MonitorAssistSelection
    private let assist: MonitorAssistState<Looks>
    private let stores: AssistPanelStores?
    private let looks: FalseColorLooks
    private let haptics: OperatorHaptics
    private let transfer: MonitorTransfer?
    private let clipByte: Int
    private let viewport: CGSize
    private let safeArea: EdgeInsets
    private let available: Set<MonitorAssistSelection>
    private let onDismiss: () -> Void
    private let preview: (MonitorAssistSelection) -> Preview
    private let lookMenu: () -> LookMenu
    private let signalOptions: MonitorOperatorSignalOptions
    private let audioAvailable: Bool?

    public init(tool: MonitorAssistSelection, assist: MonitorAssistState<Looks>,
        stores: AssistPanelStores?, looks: FalseColorLooks, palette: Palette.Type,
        haptics: OperatorHaptics, transfer: MonitorTransfer, clipByte: Int,
        viewport: CGSize, safeArea: EdgeInsets = EdgeInsets(),
        available: Set<MonitorAssistSelection> = Set(MonitorAssistSelection.settingsCases),
        signalOptions: MonitorOperatorSignalOptions = .init(),
        audioAvailable: Bool? = nil,
        onDismiss: @escaping () -> Void,
        @ViewBuilder preview: @escaping (MonitorAssistSelection) -> Preview,
        @ViewBuilder lookMenu: @escaping () -> LookMenu) {
        self.tool = tool; self.assist = assist; self.stores = stores; self.looks = looks
        self.haptics = haptics; self.transfer = transfer; self.clipByte = clipByte
        self.viewport = viewport; self.safeArea = safeArea; self.available = available
        self.onDismiss = onDismiss; self.preview = preview; self.lookMenu = lookMenu
        self.signalOptions = signalOptions
        self.audioAvailable = audioAvailable
    }

    /// An explicit unknown source keeps exposure menus unavailable without a default transfer.
    public init(tool: MonitorAssistSelection, assist: MonitorAssistState<Looks>,
        stores: AssistPanelStores?, looks: FalseColorLooks, palette: Palette.Type,
        haptics: OperatorHaptics, sourceTransfer: MonitorTransfer?, clipByte: Int,
        viewport: CGSize, safeArea: EdgeInsets = EdgeInsets(),
        available: Set<MonitorAssistSelection> = Set(MonitorAssistSelection.settingsCases),
        signalOptions: MonitorOperatorSignalOptions = .init(),
        audioAvailable: Bool? = nil,
        onDismiss: @escaping () -> Void,
        @ViewBuilder preview: @escaping (MonitorAssistSelection) -> Preview,
        @ViewBuilder lookMenu: @escaping () -> LookMenu) {
        self.tool = tool; self.assist = assist; self.stores = stores; self.looks = looks
        self.haptics = haptics; self.transfer = sourceTransfer; self.clipByte = clipByte
        self.viewport = viewport; self.safeArea = safeArea; self.available = available
        self.onDismiss = onDismiss; self.preview = preview; self.lookMenu = lookMenu
        self.signalOptions = signalOptions
        self.audioAvailable = audioAvailable
    }

    private var tools: [MonitorAssistSelection] {
        (MonitorAssistSelection.settingsCases + (signalOptions.instantReview == nil ? [] : [.instantReview])).filter {
            available.contains($0) && ($0.hasConfiguration || $0 == .instantReview)
                && ($0 != .audioMeters || (audioAvailable ?? assist.cameraHasAudio))
        }
    }

    private func descriptor(_ tool: MonitorAssistSelection) -> MonitorInspectorTool<MonitorAssistSelection> {
        MonitorInspectorTool(value: tool, title: tool.title, label: tool.rawValue, contentStyle: .fullWidth)
    }

    public var body: some View {
        MonitorToolInspector(selection: descriptor(tool), tools: tools.map(descriptor),
            viewport: viewport, safeArea: safeArea, onSelect: { assist.configureTool = $0 }, onDismiss: onDismiss
        ) { selection in
            if let shared = selection.sharedTool { MonitorAssistToolGlyph(tool: shared, size: 17) }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                preview(tool)
                if tool == .waveform || tool == .parade { menu }
                else { MonitorInspectorCard { menu } }
            }
        } footer: {
            if tool == .lut { MonitorOperatorLookComparison(assist: assist, haptics: haptics, exposure: .provider) }
        }
    }

    private var menu: some View {
        MonitorOperatorAssistMenu(tool: tool, assist: assist, stores: stores, looks: looks,
            palette: Palette.self, haptics: haptics, sourceTransfer: transfer, clipByte: clipByte,
            signalOptions: signalOptions,
            lookMenu: lookMenu)
    }

}

/// The integration supplies its coherent look catalogue; every other menu uses the common stores.
public struct MonitorOperatorAssistMenu<Looks: MonitorLookProvider, Palette: LiveChromePalette,
    LookMenu: View>: View {
    private let tool: MonitorAssistSelection
    private let assist: MonitorAssistState<Looks>
    private let stores: AssistPanelStores?
    private let looks: FalseColorLooks
    private let haptics: OperatorHaptics
    private let transfer: MonitorTransfer?
    private let clipByte: Int
    private let lookMenu: () -> LookMenu
    private let signalOptions: MonitorOperatorSignalOptions

    public init(tool: MonitorAssistSelection, assist: MonitorAssistState<Looks>,
        stores: AssistPanelStores?, looks: FalseColorLooks, palette: Palette.Type,
        haptics: OperatorHaptics, transfer: MonitorTransfer, clipByte: Int,
        signalOptions: MonitorOperatorSignalOptions = .init(),
        @ViewBuilder lookMenu: @escaping () -> LookMenu) {
        self.tool = tool; self.assist = assist; self.stores = stores; self.looks = looks
        self.haptics = haptics; self.transfer = transfer; self.clipByte = clipByte; self.lookMenu = lookMenu
        self.signalOptions = signalOptions
    }

    /// An explicit unknown source keeps exposure menus unavailable without a default transfer.
    public init(tool: MonitorAssistSelection, assist: MonitorAssistState<Looks>,
        stores: AssistPanelStores?, looks: FalseColorLooks, palette: Palette.Type,
        haptics: OperatorHaptics, sourceTransfer: MonitorTransfer?, clipByte: Int,
        signalOptions: MonitorOperatorSignalOptions = .init(),
        @ViewBuilder lookMenu: @escaping () -> LookMenu) {
        self.tool = tool; self.assist = assist; self.stores = stores; self.looks = looks
        self.haptics = haptics; self.transfer = sourceTransfer; self.clipByte = clipByte; self.lookMenu = lookMenu
        self.signalOptions = signalOptions
    }

    @ViewBuilder public var body: some View {
        switch tool {
        case .peaking: PeakingAssist.longPressMenu(assist: assist, palette: Palette.self, haptics: haptics)
        case .falseColor:
            if let menu = signalOptions.falseColor { menu }
            else if let transfer { FalseColorAssist.commonMenu(assist: assist, looks: looks,
                haptics: haptics, transfer: transfer, clipByte: clipByte,
                referenceDisplayAvailable: stores != nil && signalOptions.referenceAvailable != false) }
        case .zebra:
            if let menu = signalOptions.zebra { menu }
            else if let stores, let transfer { ZebraAssist.longPressMenu(assist: assist, stores: stores, palette: Palette.self,
                haptics: haptics, transfer: transfer, clipByte: clipByte) }
        case .lut: lookMenu()
        case .waveform: if let stores { WaveformAssist.longPressMenu(assist: assist, stores: stores, haptics: haptics, supportsCalibratedReferences: transfer != nil) }
        case .parade: if let stores { ParadeAssist.longPressMenu(assist: assist, stores: stores, haptics: haptics, supportsCalibratedReferences: transfer != nil) }
        case .histogram:
            if transfer == nil {
                Text("Encoded code percentage. Source calibration unavailable.")
                    .font(MonitorTheme.font(11)).foregroundStyle(MonitorTheme.faint)
            } else if let stores { HistogramAssist.longPressMenu(assist: assist, stores: stores, haptics: haptics) }
        case .vectorscope: if let stores { VectorscopeAssist.longPressMenu(assist: assist, stores: stores, haptics: haptics) }
        case .trafficLights: if let stores { TrafficLightsAssist.longPressMenu(assist: assist, stores: stores, haptics: haptics) }
        case .ndMeter: if let stores { NDAssist.longPressMenu(stores: stores, haptics: haptics) }
        case .guides: GuidesAssist.longPressMenu(assist: assist, haptics: haptics)
        case .grid: GridAssist.longPressMenu(assist: assist, haptics: haptics)
        case .crosshair: CrosshairAssist.longPressMenu(assist: assist)
        case .mirror: MirrorAssist.longPressMenu(assist: assist, haptics: haptics)
        case .audioMeters: if let stores { AudioAssist.longPressMenu(assist: assist, stores: stores, haptics: haptics) }
        case .desqueeze: DesqueezeAssist.longPressMenu(assist: assist, haptics: haptics)
        case .level: if let menu = signalOptions.level { menu }
        case .instantReview: if let menu = signalOptions.instantReview { menu }
        default: EmptyView()
        }
    }
}

/// Input exposure and split controls stay pinned below the catalogue in either orientation.
/// Exposure shows only for a provider whose picture applies it (`appliesLUTExposure`).
public struct MonitorOperatorLookComparison<Looks: MonitorLookProvider>: View {
    private let assist: MonitorAssistState<Looks>
    private let haptics: OperatorHaptics
    private enum ExposureSource { case provider, legacy(Bool?) }
    private let exposureSource: ExposureSource
    private let onArm: (() -> Void)?
    private let exposureTitle = "Exposure"
    private let exposureHelp = "Input stops before the cube. Pull 1–2 after ETTR."

    /// The source provider owns availability for the canonical comparison.
    public enum Exposure: Sendable { case provider }

    public init(assist: MonitorAssistState<Looks>, haptics: OperatorHaptics, exposure: Exposure) {
        self.assist = assist; self.haptics = haptics
        switch exposure { case .provider: exposureSource = .provider }
        onArm = nil
    }

    /// Published call forms retain their original availability default and arming callback.
    @available(*, deprecated, message: "Use the explicit provider exposure path for shared look composition.")
    public init(assist: MonitorAssistState<Looks>, haptics: OperatorHaptics,
        exposureAvailable: Bool? = true, onArm: (() -> Void)? = nil) {
        self.assist = assist; self.haptics = haptics
        exposureSource = .legacy(exposureAvailable); self.onArm = onArm
    }

    private var exposureVisible: Bool {
        switch exposureSource {
        case .provider: assist.looks.appliesLUTExposure
        case .legacy(let available): available == true
        }
    }

    public var body: some View {
        MonitorInspectorCard {
            VStack(spacing: 0) {
                if exposureVisible {
                    MonitorSettingsInlineRow(title: exposureTitle, help: exposureHelp,
                        showTopDivider: false, stacked: true) {
                        HStack(spacing: 9) {
                            Slider(value: Binding(get: { assist.lutExposureStops },
                                set: { assist.nudgeLUTExposure($0 - assist.lutExposureStops) }),
                                in: LUTExposureCompensation.minStops...LUTExposureCompensation.maxStops,
                                step: LUTExposureCompensation.step)
                                .tint(MonitorTheme.accent).accessibilityLabel(exposureTitle)
                                .accessibilityHint(exposureHelp)
                            Text(LUTExposureCompensation.label(assist.lutExposureStops) + " ST")
                                .font(MonitorTheme.font(11, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(assist.lutExposureStops == 0 ? MonitorTheme.text : MonitorTheme.accent)
                                .frame(width: 58, alignment: .trailing)
                        }
                    }.sensoryFeedback(trigger: assist.lutExposureStops) { _, _ in
                        haptics.isEnabled() ? .selection : nil
                    }
                }
                MonitorSettingsSwitchInlineRow(title: "50 / 50 split", isOn: assist.splitComparison,
                    feedback: haptics.selection) {
                    assist.splitComparison.toggle()
                    if assist.splitComparison {
                        if let onArm { onArm() }
                        else if !assist.lutArmed { assist.armLastLUT() }
                    }
                    assist.persist()
                }
                if assist.splitComparison {
                    MonitorSegmentedControl(options: MonitorLookSplitOrientation.allCases,
                        selection: Binding(get: { assist.splitVertical ? .leftRight : .topBottom },
                            set: { assist.splitVertical = $0 == .leftRight; assist.persist() }),
                        title: { $0.rawValue }).padding(.bottom, 8)
                }
            }
        }
    }
}

private enum MonitorLookSplitOrientation: String, CaseIterable {
    case leftRight = "Left / Right"
    case topBottom = "Top / Bottom"
}
#endif
