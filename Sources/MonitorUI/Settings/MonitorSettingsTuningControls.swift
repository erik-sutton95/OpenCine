#if os(iOS)
import SwiftUI

public struct MonitorSettingsPercentSlider: View {
    @Binding private var value: Int
    private let range: ClosedRange<Int>
    private let tint: Color
    private let textColor: Color
    public init(value: Binding<Int>, range: ClosedRange<Int>, tint: Color = MonitorTheme.accent,
        textColor: Color = MonitorTheme.text) {
        self._value = value; self.range = range; self.tint = tint; self.textColor = textColor
    }
    public var body: some View {
        HStack(spacing: 9) {
            Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .tint(tint).frame(minWidth: 120, idealWidth: 190)
            Text("\(value)%")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(textColor).frame(width: 40, alignment: .trailing).monospacedDigit()
        }
    }
}

public struct MonitorSettingsColorDot<Value: Hashable> {
    public let value: Value
    public let title: String
    public let color: Color
    public init(value: Value, title: String, color: Color) {
        self.value = value; self.title = title; self.color = color
    }
}

/// Native color cells retain their 44 point hit targets and source-provided swatches.
public struct MonitorSettingsColorDots<Value: Hashable>: View {
    private let colors: [MonitorSettingsColorDot<Value>]
    private let selected: Value
    private let compact: Bool
    private let background: Color
    private let border: Color
    private let onSelect: (Value) -> Void
    public init(colors: [MonitorSettingsColorDot<Value>], selected: Value, compact: Bool = false,
        background: Color = MonitorTheme.canvas, border: Color = MonitorTheme.border,
        onSelect: @escaping (Value) -> Void) {
        self.colors = colors; self.selected = selected; self.compact = compact
        self.background = background; self.border = border; self.onSelect = onSelect
    }
    public var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            MonitorSnapshotRows(colors, id: \.value) { color in
                Button {
                    guard color.value != selected else { return }
                    onSelect(color.value)
                } label: {
                    Circle().fill(color.color)
                        .frame(width: compact ? 15 : 13, height: compact ? 15 : 13)
                        .frame(width: 36, height: 36)
                        .background(background.opacity(0.5), in: Circle())
                        .overlay(Circle().stroke(color.value == selected ? color.color : border,
                            lineWidth: color.value == selected ? 2 : 1))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel(color.title)
            }
        }
    }
}

/// Fraction glyphs show the compact notation while accessibility speaks the full label.
public struct MonitorSettingsFractionControl<Value: Hashable>: View {
    private let options: [Value]
    private let selected: Value
    private let compact: Bool
    private let text: Color
    private let muted: Color
    private let background: Color
    private let selectedFill: Color
    private let border: Color
    private let title: (Value) -> String
    private let glyph: (Value) -> String
    private let onSelect: (Value) -> Void
    public init(options: [Value], selected: Value, compact: Bool = false,
        text: Color = MonitorTheme.text, muted: Color = MonitorTheme.muted,
        background: Color = MonitorTheme.canvas, selectedFill: Color = MonitorTheme.surface,
        border: Color = MonitorTheme.border, title: @escaping (Value) -> String,
        glyph: @escaping (Value) -> String, onSelect: @escaping (Value) -> Void) {
        self.options = options; self.selected = selected; self.compact = compact
        self.text = text; self.muted = muted; self.background = background
        self.selectedFill = selectedFill; self.border = border
        self.title = title; self.glyph = glyph; self.onSelect = onSelect
    }
    public var body: some View {
        HStack(spacing: 4) {
            MonitorSnapshotRows(options, id: \.self) { option in
                let active = option == selected
                Button { onSelect(option) } label: {
                    Text(glyph(option))
                        .font(MonitorTheme.font(compact ? 12 : 11, weight: active ? .semibold : .medium))
                        .foregroundStyle(active ? text : muted).lineLimit(1)
                        .frame(maxWidth: .infinity).frame(minWidth: 46, minHeight: 34)
                        .background(active ? selectedFill : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }.accessibilityLabel(title(option))
            }
        }.padding(4)
            .background(background.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(border, lineWidth: 1))
            .frame(maxWidth: .infinity)
    }
}
#endif
