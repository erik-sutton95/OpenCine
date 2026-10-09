#if os(iOS)
import OpenCineMedia
import SwiftUI

public struct MonitorPeakingMenu: View {
    @Binding private var options: MonitorPeakingOptions
    private let colors: [MonitorSettingsColorDot<MonitorPeakingColor>]
    private let compact: Bool
    private let sensitivityHelp: String
    private let colorHelp: String
    private let feedback: () -> Void
    public init(options: Binding<MonitorPeakingOptions>, colors: [MonitorSettingsColorDot<MonitorPeakingColor>],
        sensitivityHelp: String, colorHelp: String, compact: Bool = false, feedback: @escaping () -> Void = {}) {
        self._options = options; self.colors = colors; self.sensitivityHelp = sensitivityHelp
        self.colorHelp = colorHelp; self.compact = compact; self.feedback = feedback
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonitorSettingsInlineRow(title: "Sensitivity", help: sensitivityHelp, showTopDivider: false, stacked: true) {
                MonitorSegmentedControl(options: MonitorPeakingSense.allCases, selection: $options.sensitivity,
                    compact: compact, stacked: true, title: { $0.rawValue }, onSelectionFeedback: feedback)
                    .buttonStyle(MonitorSettingsButtonStyle())
            }
            MonitorSettingsInlineRow(title: "Color", help: colorHelp, stacked: compact) {
                MonitorSettingsColorDots(colors: colors, selected: options.color, compact: compact) {
                    feedback(); options.color = $0
                }.buttonStyle(MonitorSettingsButtonStyle())
            }
        }
    }
}

/// Reference calibration and source-specific scale labels are resolved by the host.
public struct MonitorFalseColorMenu<Scale: Hashable>: View {
    private let scales: [Scale]
    @Binding private var scale: Scale
    @Binding private var referenceEnabled: Bool
    private let read709: Binding<Bool>?
    private let reference: MonitorFalseColorReferenceValues?
    private let title: (Scale) -> String
    private let scaleHelp: String
    private let readHelp: String
    private let referenceHelp: String
    private let compact: Bool
    private let referenceDisplayAvailable: Bool
    private let selectionFeedback: () -> Void
    private let readFeedback: () -> Void
    private let referenceFeedback: () -> Void
    private let onReferenceEnabled: () -> Void
    public init(scales: [Scale], scale: Binding<Scale>, referenceEnabled: Binding<Bool>,
        read709: Binding<Bool>? = nil, reference: MonitorFalseColorReferenceValues,
        title: @escaping (Scale) -> String, scaleHelp: String, readHelp: String, referenceHelp: String,
        compact: Bool = false, referenceDisplayAvailable: Bool = true, selectionFeedback: @escaping () -> Void = {},
        readFeedback: @escaping () -> Void = {}, referenceFeedback: @escaping () -> Void = {},
        onReferenceEnabled: @escaping () -> Void = {}) {
        self.scales = scales; self._scale = scale; self._referenceEnabled = referenceEnabled
        self.read709 = read709; self.reference = reference; self.title = title
        self.scaleHelp = scaleHelp; self.readHelp = readHelp; self.referenceHelp = referenceHelp
        self.compact = compact; self.referenceDisplayAvailable = referenceDisplayAvailable
        self.selectionFeedback = selectionFeedback; self.readFeedback = readFeedback
        self.referenceFeedback = referenceFeedback; self.onReferenceEnabled = onReferenceEnabled
    }
    /// An unavailable source reference is omitted without inventing calibration values.
    public init(scales: [Scale], scale: Binding<Scale>, referenceEnabled: Binding<Bool>,
        read709: Binding<Bool>? = nil, optionalReference: MonitorFalseColorReferenceValues?,
        title: @escaping (Scale) -> String, scaleHelp: String, readHelp: String, referenceHelp: String,
        compact: Bool = false, referenceDisplayAvailable: Bool = true, selectionFeedback: @escaping () -> Void = {},
        readFeedback: @escaping () -> Void = {}, referenceFeedback: @escaping () -> Void = {},
        onReferenceEnabled: @escaping () -> Void = {}) {
        self.scales = scales; self._scale = scale; self._referenceEnabled = referenceEnabled
        self.read709 = read709; self.reference = optionalReference; self.title = title
        self.scaleHelp = scaleHelp; self.readHelp = readHelp; self.referenceHelp = referenceHelp
        self.compact = compact; self.referenceDisplayAvailable = referenceDisplayAvailable
        self.selectionFeedback = selectionFeedback; self.readFeedback = readFeedback
        self.referenceFeedback = referenceFeedback; self.onReferenceEnabled = onReferenceEnabled
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonitorSettingsInlineRow(title: "Scale", help: scaleHelp, showTopDivider: false, stacked: true) {
                MonitorSegmentedControl(options: scales, selection: $scale, compact: compact,
                    stacked: true, title: title, onSelectionFeedback: selectionFeedback)
                    .buttonStyle(MonitorSettingsButtonStyle())
            }
            if let read709 {
                MonitorSettingsInlineRow(title: "Read", help: readHelp, stacked: true) {
                    MonitorSegmentedControl(options: [false, true], selection: read709, compact: compact,
                        stacked: true, title: { $0 ? "709" : "LOG" }, onSelectionFeedback: readFeedback)
                        .buttonStyle(MonitorSettingsButtonStyle())
                }
            }
            if let reference {
                MonitorSettingsInlineRow(title: "Reference key", stacked: true) {
                    MonitorFalseColorReference(values: reference, inspector: true)
                        .accessibilityLabel("False color reference key")
                }
            }
            if referenceDisplayAvailable {
                MonitorSettingsSwitchInlineRow(title: "Reference Display", help: referenceHelp, stacked: compact,
                    isOn: referenceEnabled, feedback: referenceFeedback) {
                    referenceEnabled.toggle()
                    if referenceEnabled { onReferenceEnabled() }
                }
            }
        }
    }
}

/// A native editor receives a stored threshold binding and its source-resolved readout.
public struct MonitorZebraZone<Paint: Hashable> {
    let enabled: Binding<Bool>
    let threshold: Binding<Double>
    let displayValue: Int
    let colors: [MonitorSettingsColorDot<Paint>]
    let paint: Binding<Paint>
    public init(enabled: Binding<Bool>, threshold: Binding<Double>, displayValue: Int,
        colors: [MonitorSettingsColorDot<Paint>], paint: Binding<Paint>) {
        self.enabled = enabled; self.threshold = threshold; self.displayValue = displayValue
        self.colors = colors; self.paint = paint
    }
}

/// A known, source-calibrated integer editor. Absence lives on the zone, never as a zero value.
public struct MonitorZebraNumberEntry {
    let value: Binding<Int>
    let maximum: Int
    let identifier: String
    public init(value: Binding<Int>, maximum: Int, identifier: String = "") {
        precondition(maximum >= 0)
        self.value = value; self.maximum = maximum; self.identifier = identifier
    }
}

/// Native direct entry can configure a zone before it is enabled; the source owns conversion.
public struct MonitorZebraNumberZone<Paint: Hashable> {
    let enabled: Binding<Bool>
    let entry: MonitorZebraNumberEntry?
    let colors: [MonitorSettingsColorDot<Paint>]
    let paint: Binding<Paint>
    public init(enabled: Binding<Bool>, entry: MonitorZebraNumberEntry?,
        colors: [MonitorSettingsColorDot<Paint>], paint: Binding<Paint>) {
        self.enabled = enabled; self.entry = entry; self.colors = colors; self.paint = paint
    }
}

public struct MonitorZebraMenu<Unit: Hashable, Paint: Hashable>: View {
    private let units: [Unit]
    @Binding private var unit: Unit
    private let title: (Unit) -> String
    private let unitsTitle: String
    private let unitsHelp: String
    private let highlightHelp: String
    private let midtoneHelp: String
    private enum Zone {
        case slider(MonitorZebraZone<Paint>)
        case number(MonitorZebraNumberZone<Paint>)
    }
    private let highlight: Zone
    private let midtone: Zone
    private let compact: Bool
    private let selectionFeedback: () -> Void
    private let toggleFeedback: () -> Void
    public init(units: [Unit], unit: Binding<Unit>, title: @escaping (Unit) -> String,
        unitsTitle: String, unitsHelp: String, highlightHelp: String, midtoneHelp: String,
        highlight: MonitorZebraZone<Paint>, midtone: MonitorZebraZone<Paint>, compact: Bool = false,
        selectionFeedback: @escaping () -> Void = {}, toggleFeedback: @escaping () -> Void = {}) {
        self.units = units; self._unit = unit; self.title = title; self.unitsTitle = unitsTitle
        self.unitsHelp = unitsHelp; self.highlightHelp = highlightHelp; self.midtoneHelp = midtoneHelp
        self.highlight = .slider(highlight); self.midtone = .slider(midtone); self.compact = compact
        self.selectionFeedback = selectionFeedback; self.toggleFeedback = toggleFeedback
    }
    public init(units: [Unit], unit: Binding<Unit>, title: @escaping (Unit) -> String,
        unitsTitle: String, unitsHelp: String, highlightHelp: String, midtoneHelp: String,
        highlight: MonitorZebraNumberZone<Paint>, midtone: MonitorZebraNumberZone<Paint>, compact: Bool = false,
        selectionFeedback: @escaping () -> Void = {}, toggleFeedback: @escaping () -> Void = {}) {
        self.units = units; self._unit = unit; self.title = title; self.unitsTitle = unitsTitle
        self.unitsHelp = unitsHelp; self.highlightHelp = highlightHelp; self.midtoneHelp = midtoneHelp
        self.highlight = .number(highlight); self.midtone = .number(midtone); self.compact = compact
        self.selectionFeedback = selectionFeedback; self.toggleFeedback = toggleFeedback
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonitorSettingsInlineRow(title: unitsTitle, help: unitsHelp, showTopDivider: false, stacked: compact) {
                MonitorSegmentedControl(options: units, selection: $unit, compact: compact, stacked: compact,
                    title: title, onSelectionFeedback: selectionFeedback).buttonStyle(MonitorSettingsButtonStyle())
            }
            zone(title: "Highlight", help: highlightHelp, values: highlight)
            zone(title: "Midtone", help: midtoneHelp, values: midtone)
        }
    }
    @ViewBuilder private func zone(title: String, help: String, values: Zone) -> some View {
        switch values {
        case .slider(let values): sliderZone(title: title, help: help, values: values)
        case .number(let values): numberZone(title: title, help: help, values: values)
        }
    }
    private func sliderZone(title: String, help: String, values: MonitorZebraZone<Paint>) -> some View {
        VStack(spacing: 0) {
            MonitorSettingsSwitchInlineRow(title: title, help: help, isOn: values.enabled.wrappedValue,
                feedback: toggleFeedback) { values.enabled.wrappedValue.toggle() }
            VStack(alignment: .leading, spacing: 0) {
                MonitorSettingsInlineRow(title: "Threshold") {
                    HStack(spacing: 9) {
                        Slider(value: values.threshold, in: 0...100, step: 1)
                            .frame(minWidth: 76, idealWidth: 110, maxWidth: 140)
                            .tint(MonitorTheme.accent).accessibilityLabel("\(title) threshold")
                        Text("\(values.displayValue)").font(MonitorTheme.font(12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(MonitorTheme.secondary).frame(width: 34, alignment: .trailing)
                    }
                }
                MonitorSettingsInlineRow(title: "Colour") {
                    MonitorSettingsColorDots(colors: values.colors, selected: values.paint.wrappedValue, compact: compact) {
                        selectionFeedback(); values.paint.wrappedValue = $0
                    }.buttonStyle(MonitorSettingsButtonStyle())
                }
            }.padding(.leading, 14).opacity(values.enabled.wrappedValue ? 1 : 0.4)
                .disabled(!values.enabled.wrappedValue)
        }
    }
    private func numberZone(title: String, help: String, values: MonitorZebraNumberZone<Paint>) -> some View {
        MonitorSettingsInlineRow(title: title, help: help, stacked: compact) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    numberSwitch(title: title, values: values)
                    numberEntry(values.entry)
                    if compact { Spacer(minLength: 4) }
                    numberColors(values)
                }.fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        numberSwitch(title: title, values: values)
                        numberEntry(values.entry)
                    }
                    numberColors(values)
                }
            }
        }
    }
    private func numberSwitch(title: String, values: MonitorZebraNumberZone<Paint>) -> some View {
        Button {
            toggleFeedback(); values.enabled.wrappedValue.toggle()
        } label: {
            MonitorSettingsSwitchGraphic(isOn: values.enabled.wrappedValue)
        }.buttonStyle(MonitorSettingsButtonStyle())
            .accessibilityLabel(title).accessibilityValue(values.enabled.wrappedValue ? "On" : "Off")
    }
    @ViewBuilder private func numberEntry(_ entry: MonitorZebraNumberEntry?) -> some View {
        if let entry {
            MonitorSettingsNumberField(value: entry.value, maximum: entry.maximum)
                .accessibilityIdentifier(entry.identifier)
        }
    }
    private func numberColors(_ values: MonitorZebraNumberZone<Paint>) -> some View {
        MonitorSettingsColorDots(colors: values.colors, selected: values.paint.wrappedValue, compact: compact) {
            selectionFeedback(); values.paint.wrappedValue = $0
        }.buttonStyle(MonitorSettingsButtonStyle())
    }
}
#endif
