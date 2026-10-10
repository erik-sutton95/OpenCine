#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineMedia
import SwiftUI

public enum MonitorOperatorAssistResetPolicy: Equatable, Sendable {
    case allOptions
    case plotControls
}

/// Complete common tool-menu assembly and reset policy over the existing explicit stores.
public struct MonitorOperatorAssistSettings<Looks: MonitorLookProvider, Palette: LiveChromePalette>: View {
    private let assist: MonitorAssistState<Looks>
    private let stores: AssistPanelStores
    private let looks: FalseColorLooks
    private let haptics: OperatorHaptics
    private let transfer: MonitorTransfer
    private let clipByte: Int
    private let available: Set<MonitorAssistSelection>
    private let signalOptions: MonitorOperatorSignalOptions
    private let resetPolicy: MonitorOperatorAssistResetPolicy

    public init(assist: MonitorAssistState<Looks>, stores: AssistPanelStores,
        looks: FalseColorLooks, palette: Palette.Type, haptics: OperatorHaptics,
        transfer: MonitorTransfer, clipByte: Int,
        available: Set<MonitorAssistSelection> = [.falseColor, .zebra, .waveform, .parade,
            .histogram, .vectorscope, .peaking, .trafficLights],
        signalOptions: MonitorOperatorSignalOptions = .init(), resetPolicy: MonitorOperatorAssistResetPolicy = .allOptions) {
        self.assist = assist; self.stores = stores; self.looks = looks; self.haptics = haptics
        self.transfer = transfer; self.clipByte = clipByte; self.available = available
        self.signalOptions = signalOptions; self.resetPolicy = resetPolicy
    }

    public var body: some View {
        MonitorViewAssistSettings(sections: sections).buttonStyle(.monitorTapTarget)
    }

    private var sections: [MonitorAssistSettingsSection] {
        var result: [MonitorAssistSettingsSection] = []
        if available.contains(.falseColor) {
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
        if available.contains(.zebra) {
            let menu = signalOptions.zebra ?? AnyView(ZebraAssist.longPressMenu(assist: assist, stores: stores,
                palette: Palette.self, haptics: haptics, transfer: transfer, clipByte: clipByte,
                compact: true).assistMenu(transfer: transfer, clipByte: clipByte))
            result.append(.zebra(menu, reset: {
                haptics.selection()
                if let reset = signalOptions.resetZebra { reset(); return }
                assist.setZebraOptions(.default, stores: stores); assist.persist()
            }))
        }
        if available.contains(.waveform) {
            result.append(.waveform(WaveformAssist.longPressMenu(assist: assist, stores: stores,
                haptics: haptics, compact: true).assistMenu, reset: {
                haptics.selection()
                if resetPolicy == .plotControls {
                    let base = MonitorWaveformOptions.default
                    stores.waveform.options.mode = base.mode; stores.waveform.options.guides = base.guides
                    stores.waveform.options.brightness = base.brightness
                } else { stores.waveform.options = .default }
            }))
        }
        if available.contains(.parade) {
            result.append(.parade(ParadeAssist.longPressMenu(assist: assist, stores: stores,
                haptics: haptics, compact: true).assistMenu, reset: {
                haptics.selection()
                if resetPolicy == .plotControls {
                    let base = MonitorParadeOptions.default
                    stores.parade.options.mode = base.mode; stores.parade.options.guides = base.guides
                    stores.parade.options.brightness = base.brightness
                } else { stores.parade.options = .default }
            }))
        }
        if available.contains(.histogram) {
            result.append(.histogram(HistogramAssist.longPressMenu(assist: assist, stores: stores,
                haptics: haptics, compact: true).assistMenu, reset: {
                haptics.selection()
                if resetPolicy == .plotControls {
                    stores.histogram.options.trafficLights = MonitorHistogramOptions.default.trafficLights
                    assist.crushClipCompensation = .zero; assist.persist()
                } else { stores.histogram.options = .default }
            }))
        }
        if available.contains(.vectorscope) {
            result.append(.vectorscope(VectorscopeAssist.longPressMenu(assist: assist, stores: stores,
                haptics: haptics, compact: true).assistMenu, reset: {
                haptics.selection()
                if resetPolicy == .plotControls {
                    let base = MonitorVectorscopeOptions.default
                    stores.vectorscope.options.zoom = base.zoom; stores.vectorscope.options.brightness = base.brightness
                } else { stores.vectorscope.options = .default }
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
                haptics.selection(); assist.crushClipCompensation = TrafficLightsAssist.defaultCompensation
                if resetPolicy == .plotControls { stores.trafficLights.scale = 1; stores.trafficLights.persist() }
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
