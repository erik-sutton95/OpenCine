#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineMedia
import SwiftUI

/// Complete common tool-menu assembly and one reset semantics over the existing explicit
/// stores: every Reset restores the plot's full option set (mode, guides, brightness, size
/// and place) to the shared defaults. App-specific extras go through signalOptions.
public struct MonitorOperatorAssistSettings<Looks: MonitorLookProvider, Palette: LiveChromePalette>: View {
    private let assist: MonitorAssistState<Looks>
    private let stores: AssistPanelStores
    private let looks: FalseColorLooks
    private let haptics: OperatorHaptics
    private let transfer: MonitorTransfer
    private let clipByte: Int
    private let available: Set<MonitorAssistSelection>
    private let signalOptions: MonitorOperatorSignalOptions

    public init(assist: MonitorAssistState<Looks>, stores: AssistPanelStores,
        looks: FalseColorLooks, palette: Palette.Type, haptics: OperatorHaptics,
        transfer: MonitorTransfer, clipByte: Int,
        available: Set<MonitorAssistSelection> = [.falseColor, .zebra, .waveform, .parade,
            .histogram, .vectorscope, .peaking, .trafficLights],
        signalOptions: MonitorOperatorSignalOptions = .init()) {
        self.assist = assist; self.stores = stores; self.looks = looks; self.haptics = haptics
        self.transfer = transfer; self.clipByte = clipByte; self.available = available
        self.signalOptions = signalOptions
    }

    public var body: some View {
        MonitorViewAssistSettings(sections: sections).buttonStyle(.monitorTapTarget)
    }

    private var sections: [MonitorAssistSettingsSection] {
        var result: [MonitorAssistSettingsSection] = []
        // A curve-reading tool explains its wait instead of offering settings (product ruling 2026-10-16).
        for tool in [MonitorAssistSelection.falseColor, .zebra] where available.contains(tool) && !assist.offers(tool) {
            if let shared = tool.sharedTool {
                result.append(.unavailable(tool: shared, message: MonitorSettingsCopy.sourceCurveUnknown))
            }
        }
        if available.contains(.falseColor), assist.offers(.falseColor) {
            let menu = signalOptions.falseColor ?? AnyView(FalseColorAssist.commonMenu(assist: assist, looks: looks,
                haptics: haptics, compact: true, transfer: transfer, clipByte: clipByte))
            result.append(.falseColor(menu, reset: {
                haptics.selection()
                if let reset = signalOptions.resetFalseColor { reset(); return }
                assist.falseColorScale = FalseColorAssist.Options.default.scale
                assist.falseColorReference = FalseColorAssist.Options.default.referenceEnabled
                assist.persist()
            }))
        }
        if available.contains(.zebra), assist.offers(.zebra) {
            let menu = signalOptions.zebra ?? AnyView(ZebraAssist.longPressMenu(assist: assist, stores: stores,
                palette: Palette.self, haptics: haptics, transfer: transfer, clipByte: clipByte,
                compact: true).assistMenu(transfer: transfer, clipByte: clipByte))
            result.append(.zebra(menu, reset: {
                haptics.selection()
                if let reset = signalOptions.resetZebra { reset(); return }
                var options = ZebraAssist.Options.default
                options.highlightIRE = assist.defaults.zebraHighlightIRE
                assist.setZebraOptions(options, stores: stores); assist.persist()
            }))
        }
        if available.contains(.waveform) {
            result.append(.waveform(WaveformAssist.longPressMenu(assist: assist, stores: stores,
                haptics: haptics, compact: true).assistMenu, reset: {
                haptics.selection()
                stores.waveform.options = .default
            }))
        }
        if available.contains(.parade) {
            result.append(.parade(ParadeAssist.longPressMenu(assist: assist, stores: stores,
                haptics: haptics, compact: true).assistMenu, reset: {
                haptics.selection()
                stores.parade.options = .default
            }))
        }
        if available.contains(.histogram) {
            result.append(.histogram(HistogramAssist.longPressMenu(assist: assist, stores: stores,
                haptics: haptics, compact: true).assistMenu, reset: {
                haptics.selection()
                var options = MonitorHistogramOptions.default
                options.crushClipCompensation = assist.defaults.crushClipCompensation
                stores.histogram.options = options
                assist.crushClipCompensation = assist.defaults.crushClipCompensation; assist.persist()
            }))
        }
        if available.contains(.vectorscope) {
            result.append(.vectorscope(VectorscopeAssist.longPressMenu(assist: assist, stores: stores,
                haptics: haptics, compact: true).assistMenu, reset: {
                haptics.selection()
                stores.vectorscope.options = .default
            }))
        }
        if available.contains(.peaking) {
            result.append(.peaking(PeakingAssist.longPressMenu(assist: assist, palette: Palette.self,
                haptics: haptics, compact: true).assistMenu, reset: {
                haptics.selection(); PeakingAssist.reset(assist)
            }))
        }
        if available.contains(.trafficLights) {
            result.append(.trafficLights(TrafficLightsAssist.longPressMenu(assist: assist, stores: stores,
                haptics: haptics, compact: true).assistMenu, reset: {
                haptics.selection()
                assist.crushClipCompensation = assist.defaults.crushClipCompensation
                stores.trafficLights.scale = 1; stores.trafficLights.persist()
                assist.persist()
            }))
        }
        return result
    }
}

extension FalseColorLooks {
    /// Missing official-look facts keep the reference on the reported signal.
    public static var signal: FalseColorLooks {
        FalseColorLooks(scaleHelp: "False color reads the source signal. Stops center on middle gray; IRE and Limits show monitoring levels.",
            rec709LookCurve: { _ in nil })
    }
}
#endif
