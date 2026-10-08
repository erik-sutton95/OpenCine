#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import SwiftUI
import UIKit

/// The watcher retains its grouped strip and exact hold cadence around the common assist state.
public struct MonitorWatcherToolStrip<Looks: MonitorLookProvider, Palette: LiveChromePalette>: View {
    private let assist: MonitorAssistState<Looks>
    private let haptics: OperatorHaptics
    private let isLocked: Bool
    private let showsAudio: Bool
    @Environment(\.interfaceLocked) private var environmentLocked
    @State private var edgeFades = WatcherStripEdges(leading: false, trailing: true)
    @State private var iconFrames: [MonitorAssistSelection: CGRect] = [:]
    @State private var toolbarFrame: CGRect = .zero
    private var locked: Bool { isLocked || environmentLocked }

    public init(assist: MonitorAssistState<Looks>, palette: Palette.Type, haptics: OperatorHaptics,
        isLocked: Bool = false, showsAudio: Bool = true) {
        self.assist = assist; self.haptics = haptics
        self.isLocked = isLocked; self.showsAudio = showsAudio
    }
    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            toolRow.fixedSize(horizontal: true, vertical: false)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .modifier(WatcherStripEdgeReporter(edges: $edgeFades))
        .mask(edgeFades.gradient)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.leading, 7).padding(.trailing, 14).frame(height: 58)
        .liveChromeGlass(in: RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous))
        .overlay(alignment: .leading) { scrollChevron(.leading) }
        .overlay(alignment: .trailing) { scrollChevron(.trailing) }
        .allowsHitTesting(!locked)
        .animation(.easeInOut(duration: 0.18), value: edgeFades)
        .onPreferenceChange(WatcherStripIconFrames.self) { frames in
            iconFrames = frames
            if let tool = assist.configureTool, let frame = frames[tool], frame.width > 1 {
                assist.longPressAnchor = frame
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { toolbarFrame = proxy.frame(in: .named(LiveCanvasSpace.name)) }
                    .onChange(of: proxy.frame(in: .named(LiveCanvasSpace.name))) { _, frame in toolbarFrame = frame }
            }
        }
    }
    private var toolRow: some View {
        let groups = MonitorAssistSelection.toolbarGroups
        return HStack(spacing: 2) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { divider }
                ForEach(group) { tool in button(tool) }
            }
            if showsAudio {
                if !groups.isEmpty { divider }
                button(.audioMeters)
            }
        }
    }
    private var divider: some View {
        Rectangle().fill(Palette.hairlineStrong).frame(width: 1, height: 28).padding(.horizontal, 3)
    }
    private func button(_ tool: MonitorAssistSelection) -> some View {
        WatcherStripButton(tool: tool, assist: assist, haptics: haptics, locked: locked) { selected in
            guard !locked, selected.hasConfiguration else { return }
            haptics.confirm()
            assist.longPressAnchor = iconFrames[selected] ?? toolbarFrame
            assist.configureTool = selected
            if selected == .lut { assist.showLUTPicker = false }
        }
    }
    private func scrollChevron(_ edge: HorizontalEdge) -> some View {
        (edge == .leading ? MonitorIcon.chevronLeft : MonitorIcon.chevronRight)
            .frame(width: 12, height: 12).foregroundStyle(Palette.accent)
            .shadow(color: .black.opacity(0.65), radius: 4).padding(.horizontal, 5)
            .opacity((edge == .leading ? edgeFades.leading : edgeFades.trailing) ? 1 : 0)
            .allowsHitTesting(false)
    }
}

private struct WatcherStripButton<Looks: MonitorLookProvider>: View {
    let tool: MonitorAssistSelection
    let assist: MonitorAssistState<Looks>
    let haptics: OperatorHaptics
    let locked: Bool
    let onPresent: (MonitorAssistSelection) -> Void
    @State private var buildup: Task<Void, Never>?
    var body: some View {
        MonitorAssistChip(id: tool.rawValue, isOn: assist.isOn(tool), compact: true) {
            if let shared = tool.sharedTool { MonitorAssistToolGlyph(tool: shared, size: 19) }
        }
        .contentShape(Rectangle()).minTapTarget()
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: WatcherStripIconFrames.self,
                    value: [tool: proxy.frame(in: .named(LiveCanvasSpace.name))])
            }
        }
        .onTapGesture { if !locked { assist.toggle(tool) } }
        .onLongPressGesture(minimumDuration: 0.25) {
            cancelBuildup(); onPresent(tool)
        } onPressingChanged: { pressing in
            guard tool.hasConfiguration, !locked else { return }
            if pressing { buildup = beginBuildup() } else { cancelBuildup() }
        }
        .onDisappear { cancelBuildup() }
        .onChange(of: locked) { _, nowLocked in if nowLocked { cancelBuildup() } }
    }
    private func beginBuildup() -> Task<Void, Never> {
        Task { @MainActor in
            guard haptics.isEnabled() else { return }
            let generator = UIImpactFeedbackGenerator(style: .soft)
            for intensity in [0.4, 0.65, 0.9] as [CGFloat] {
                guard !Task.isCancelled else { return }
                generator.prepare(); generator.impactOccurred(intensity: intensity)
                try? await Task.sleep(for: .seconds(0.08))
            }
        }
    }
    private func cancelBuildup() { buildup?.cancel(); buildup = nil }
}

private struct WatcherStripIconFrames: PreferenceKey {
    static let defaultValue: [MonitorAssistSelection: CGRect] = [:]
    static func reduce(value: inout [MonitorAssistSelection: CGRect], nextValue: () -> [MonitorAssistSelection: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
private struct WatcherStripEdges: Equatable {
    var leading: Bool
    var trailing: Bool
    var gradient: LinearGradient {
        LinearGradient(stops: [.init(color: leading ? .clear : .black, location: 0),
            .init(color: .black, location: leading ? 0.06 : 0),
            .init(color: .black, location: trailing ? 0.94 : 1),
            .init(color: trailing ? .clear : .black, location: 1)], startPoint: .leading, endPoint: .trailing)
    }
}
private struct WatcherStripEdgeReporter: ViewModifier {
    @Binding var edges: WatcherStripEdges
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: WatcherStripEdges.self) { geometry in
                let remaining = geometry.contentSize.width - geometry.containerSize.width - geometry.contentOffset.x
                return WatcherStripEdges(leading: geometry.contentOffset.x > 6, trailing: remaining > 28)
            } action: { _, next in edges = next }
        } else { content.onAppear { edges = .init(leading: true, trailing: true) } }
    }
}
#endif
