#if os(iOS)
import OpenCineMedia
import SwiftUI

public struct MonitorAssistHelp: View {
    private let text: String
    private let compact: Bool
    public init(_ text: String, compact: Bool = false) { self.text = text; self.compact = compact }
    public var body: some View {
        Text(text).font(MonitorTheme.font(compact ? 11 : 13)).foregroundStyle(MonitorTheme.muted)
    }
}

public struct MonitorAudioMenu: View {
    @Binding private var orientation: MonitorAudioOrientation
    @Binding private var showsDB: Bool
    private let help: String
    private let compact: Bool
    private let feedback: () -> Void
    public init(orientation: Binding<MonitorAudioOrientation>, showsDB: Binding<Bool>, help: String,
        compact: Bool = false, orientationFeedback: @escaping () -> Void = {}) {
        self._orientation = orientation; self._showsDB = showsDB; self.help = help
        self.compact = compact; self.feedback = orientationFeedback
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Orientation").font(MonitorTheme.font(11, weight: .semibold))
            MonitorSegmentedControl(options: MonitorAudioOrientation.allCases, selection: $orientation,
                stacked: true, title: { $0.rawValue }, onSelectionFeedback: feedback)
                .buttonStyle(MonitorButtonStyle())
            Toggle("Show dB values", isOn: $showsDB).font(MonitorTheme.font(12)).tint(MonitorTheme.accent)
            Text(help).font(MonitorTheme.font(compact ? 11 : 12)).foregroundStyle(MonitorTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

public struct MonitorNDMenu: View {
    @Binding private var notation: MonitorNDFilterNotation
    private let title: String
    private let notationHelp: String
    private let help: String
    private let compact: Bool
    private let feedback: () -> Void
    public init(notation: Binding<MonitorNDFilterNotation>, title: String, notationHelp: String,
        help: String, compact: Bool = false, selectionFeedback: @escaping () -> Void = {}) {
        self._notation = notation; self.title = title; self.notationHelp = notationHelp
        self.help = help; self.compact = compact; self.feedback = selectionFeedback
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonitorSettingsInlineRow(title: title, help: notationHelp, showTopDivider: false, stacked: true) {
                MonitorSegmentedControl(options: MonitorNDFilterNotation.allCases, selection: $notation,
                    compact: true, stacked: compact, title: { $0.editorLabel }, onSelectionFeedback: feedback)
                    .buttonStyle(MonitorSettingsButtonStyle())
            }
            Text(help).font(MonitorTheme.font(13)).foregroundStyle(MonitorTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

public struct MonitorMirrorMenu: View {
    @Binding private var horizontal: Bool
    @Binding private var vertical: Bool
    private let explanation: String
    private let horizontalHelp: String
    private let verticalHelp: String
    private let feedback: () -> Void
    public init(horizontal: Binding<Bool>, vertical: Binding<Bool>, explanation: String,
        horizontalHelp: String, verticalHelp: String, feedback: @escaping () -> Void = {}) {
        self._horizontal = horizontal; self._vertical = vertical; self.explanation = explanation
        self.horizontalHelp = horizontalHelp; self.verticalHelp = verticalHelp; self.feedback = feedback
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonitorAssistHelp(explanation).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8)
            MonitorSettingsSwitchInlineRow(title: "Horizontal", help: horizontalHelp, showTopDivider: false,
                isOn: horizontal, identifier: "mirror.horizontal", feedback: feedback) { horizontal.toggle() }
            MonitorSettingsSwitchInlineRow(title: "Vertical", help: verticalHelp, isOn: vertical,
                identifier: "mirror.vertical", feedback: feedback) { vertical.toggle() }
        }
    }
}

public struct MonitorGridMenu: View {
    private let selected: Set<MonitorGridOption>
    private let feedback: () -> Void
    private let onToggle: (MonitorGridOption) -> Void
    public init(selected: Set<MonitorGridOption>, feedback: @escaping () -> Void = {},
        onToggle: @escaping (MonitorGridOption) -> Void) {
        self.selected = selected; self.feedback = feedback; self.onToggle = onToggle
    }
    public var body: some View {
        VStack(spacing: 0) {
            MonitorSnapshotRows(MonitorGridOption.allCases) { option in
                MonitorSettingsSwitchInlineRow(title: option.rawValue, showTopDivider: option != .thirds,
                    isOn: selected.contains(option), feedback: feedback) { onToggle(option) }
            }
        }
    }
}

public struct MonitorGuidesMenu: View {
    @Binding private var family: MonitorGuideFamily
    @Binding private var mask: Bool
    private let selected: Set<MonitorGuideAspect>
    private let feedback: () -> Void
    private let onToggle: (MonitorGuideAspect) -> Void
    public init(family: Binding<MonitorGuideFamily>, selected: Set<MonitorGuideAspect>, mask: Binding<Bool>,
        feedback: @escaping () -> Void = {}, onToggle: @escaping (MonitorGuideAspect) -> Void) {
        self._family = family; self._mask = mask; self.selected = selected
        self.feedback = feedback; self.onToggle = onToggle
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonitorSettingsInlineRow(title: "Family", showTopDivider: false) {
                MonitorCaptureTabs(options: MonitorGuideFamily.allCases, selection: family, title: { $0.rawValue }) {
                    guard $0 != family else { return }
                    feedback(); family = $0
                }
            }
            MonitorSettingsInlineRow(title: "Ratios", stacked: true) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 6)], spacing: 6) {
                    MonitorSnapshotRows(MonitorGuideAspect.ratios(for: family)) { ratio in
                        Button { feedback(); onToggle(ratio) } label: {
                            MonitorGuideChoice(title: ratio.rawValue, isSelected: selected.contains(ratio))
                        }.buttonStyle(MonitorSettingsButtonStyle())
                            .accessibilityAddTraits(selected.contains(ratio) ? .isSelected : [])
                    }
                }
            }
            MonitorSettingsSwitchInlineRow(title: "Mask outside frame", isOn: mask, feedback: feedback) { mask.toggle() }
        }
    }
}

private struct MonitorGuideChoice: View {
    let title: String
    let isSelected: Bool
    var body: some View {
        Text(title).font(MonitorTheme.font(11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            .allowsTightening(true)
            .foregroundStyle(isSelected ? Color(red: 8 / 255, green: 25 / 255, blue: 31 / 255) : MonitorTheme.text)
            .padding(.horizontal, 2).frame(maxWidth: .infinity).frame(minHeight: 36)
            .background(isSelected ? MonitorTheme.accent : MonitorTheme.raised,
                in: RoundedRectangle(cornerRadius: MonitorTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: MonitorTheme.radius)
                .stroke(isSelected ? MonitorTheme.accent.opacity(0.16) : MonitorTheme.border, lineWidth: 1))
    }
}

public struct MonitorDesqueezeMenu: View {
    private let selected: MonitorDesqueezePreset?
    private let custom: Bool
    @Binding private var factor: Double
    @Binding private var horizontal: Bool
    private let help: String
    private let select: (MonitorDesqueezePreset?) -> Void
    private let feedback: () -> Void
    private let persist: () -> Void
    public init(selected: MonitorDesqueezePreset?, custom: Bool, factor: Binding<Double>, horizontal: Binding<Bool>,
        help: String, selectionFeedback: @escaping () -> Void = {},
        onSelect: @escaping (MonitorDesqueezePreset?) -> Void, onFinish: @escaping () -> Void) {
        self.selected = selected; self.custom = custom; self._factor = factor; self._horizontal = horizontal
        self.help = help; self.feedback = selectionFeedback; self.select = onSelect; self.persist = onFinish
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonitorSettingsInlineRow(title: "Squeeze factor", help: help, showTopDivider: false, stacked: true) {
                VStack(spacing: 6) {
                    choices(Array(MonitorDesqueezePreset.allCases.prefix(4)).map(Optional.some))
                    choices(Array(MonitorDesqueezePreset.allCases.suffix(3)).map(Optional.some) + [nil])
                }
            }
            if custom {
                MonitorSettingsInlineRow(title: "Custom", help: "Adjust from 1.00× to 2.00× in 0.01 steps.", stacked: true) {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(String(format: "%.2f×", factor))
                            .font(MonitorTheme.font(13, weight: .semibold))
                            .accessibilityIdentifier("desqueeze.factor")
                        Slider(value: $factor, in: MonitorAnamorphicDesqueeze.factorRange,
                            step: MonitorAnamorphicDesqueeze.factorStep) { if !$0 { persist() } }
                            .tint(MonitorTheme.accent).accessibilityLabel("Custom squeeze factor")
                            .accessibilityValue(String(format: "%.2f×", factor))
                    }
                }
            }
            MonitorSettingsInlineRow(title: "Direction", help: "Choose the squeeze direction of your lens or adapter.", stacked: true) {
                MonitorSegmentedControl(options: [true, false], selection: $horizontal, stacked: true,
                    title: { $0 ? "Horizontal" : "Vertical" }, onSelectionFeedback: feedback)
                    .buttonStyle(MonitorSettingsButtonStyle())
            }
        }.onDisappear(perform: persist)
    }
    private func choices(_ options: [MonitorDesqueezePreset?]) -> some View {
        MonitorSegmentedControl(options: options, selection: Binding(get: { selected }, set: { select($0) }),
            stacked: true, title: { $0?.rawValue ?? "Custom" }, onSelectionFeedback: feedback)
            .buttonStyle(MonitorSettingsButtonStyle())
    }
}
#endif
