#if os(iOS)
import SwiftUI
import UIKit

/// A tool's navigation facts. Menus are coherent control extensions, never complete app pages.
public struct MonitorInspectorTool<Value: Hashable>: Identifiable {
    public enum ContentStyle: Equatable, Sendable { case card, fullWidth }
    public let value: Value
    public let title: String
    public let label: String
    public let contentStyle: ContentStyle
    public var id: Value { value }

    public init(value: Value, title: String, label: String, contentStyle: ContentStyle = .card) {
        self.value = value; self.title = title; self.label = label; self.contentStyle = contentStyle
    }
}

/// Owns tool navigation, help, keyboard dismissal and option-card presentation in both orientations.
/// Callers supply one selected tool's menu and optional bounded preview/footer.
public struct MonitorToolInspector<Value: Hashable, Glyph: View, Content: View, Footer: View>: View {
    private let selection: MonitorInspectorTool<Value>
    private let tools: [MonitorInspectorTool<Value>]
    private let viewport: CGSize
    private let safeArea: EdgeInsets
    private let closeIdentifier: String
    private let onSelect: (Value) -> Void
    private let onDismiss: () -> Void
    private let glyph: (Value) -> Glyph
    private let content: () -> Content
    private let footer: () -> Footer
    @State private var helpVisible = false

    public init(selection: MonitorInspectorTool<Value>, tools: [MonitorInspectorTool<Value>],
        viewport: CGSize, safeArea: EdgeInsets = EdgeInsets(), closeIdentifier: String = "monitor.assist.close",
        onSelect: @escaping (Value) -> Void, onDismiss: @escaping () -> Void,
        @ViewBuilder glyph: @escaping (Value) -> Glyph,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer) {
        self.selection = selection; self.tools = tools; self.viewport = viewport; self.safeArea = safeArea
        self.closeIdentifier = closeIdentifier; self.onSelect = onSelect; self.onDismiss = onDismiss
        self.glyph = glyph; self.content = content; self.footer = footer
    }

    private var portrait: Bool { viewport.height > viewport.width }

    public var body: some View {
        MonitorInspector(title: selection.title, viewport: viewport, safeArea: safeArea,
            helpVisible: $helpVisible, closeIdentifier: closeIdentifier, onClose: dismiss) {
            ScrollView(portrait ? .horizontal : .vertical, showsIndicators: false) {
                MonitorTabStrip(vertical: !portrait) {
                    MonitorSnapshotRows(tools) { tool in
                        Button { onSelect(tool.value) } label: {
                            HStack(spacing: 7) {
                                glyph(tool.value)
                                Text(tool.label).font(MonitorTheme.font(9, weight: .semibold))
                            }
                            .foregroundStyle(tool.value == selection.value ? MonitorTheme.accent : MonitorTheme.muted)
                            .frame(width: portrait ? 88 : 96, height: 44)
                            .monitorTabSurface(selected: tool.value == selection.value, separator: tool.id != tools.first?.id)
                        }
                        .buttonStyle(MonitorTabButtonStyle()).accessibilityLabel(tool.title)
                        .accessibilityIdentifier("monitor.assist.options." + tool.label)
                        .accessibilityAddTraits(tool.value == selection.value ? .isSelected : [])
                    }
                }.padding(.horizontal, 6)
            }.monitorScrollFade(portrait ? .horizontal : .vertical)
        } content: {
            Group {
                if selection.contentStyle == .fullWidth { content() }
                else { MonitorInspectorCard { content() } }
            }.environment(\.monitorInspectorHelp, helpVisible)
        } footer: { footer() }
        .environment(\.monitorSegmentedAppearance, .inspector)
    }

    private func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        onDismiss()
    }
}
#endif
