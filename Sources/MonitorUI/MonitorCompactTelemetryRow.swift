#if os(iOS)
import MonitorPresentation
import SwiftUI

private struct AdaptiveTelemetryPaddingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    public var monitorAdaptiveTelemetryPadding: Bool {
        get { self[AdaptiveTelemetryPaddingKey.self] }
        set { self[AdaptiveTelemetryPaddingKey.self] = newValue }
    }
}

/// The same pill content and default frame, with budgeted decoration in a measured compact row.
public struct MonitorTelemetryPill<Content: View>: View {
    @Environment(\.monitorAdaptiveTelemetryPadding) private var adaptive
    @Environment(\.displayScale) private var scale
    private let width: CGFloat
    private let height: CGFloat
    private let content: () -> Content

    public init(width: CGFloat, height: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.width = width; self.height = height; self.content = content
    }

    public var body: some View {
        if adaptive {
            TelemetryPillLayout(preferredWidth: width, scale: scale) {
                content().fixedSize(horizontal: true, vertical: false)
            }.frame(height: height)
        } else {
            content().padding(.horizontal, 6).frame(width: width, height: height, alignment: .leading)
        }
    }
}

private struct TelemetryPillLayout: Layout {
    let preferredWidth: CGFloat
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let measured = content.sizeThatFits(.unspecified)
        let fit = padding(content: measured.width, width: proposal.width)
        return CGSize(width: fit.width, height: measured.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let measured = content.sizeThatFits(.unspecified)
        let fit = padding(content: measured.width, width: bounds.width)
        content.place(at: CGPoint(x: bounds.minX + fit.padding, y: bounds.midY), anchor: .leading,
            proposal: ProposedViewSize(measured))
    }

    private func padding(content: CGFloat, width: CGFloat?) -> MonitorTelemetryPadding {
        MonitorTelemetryPadding(contentWidth: Double(content), availableWidth: Double(width ?? .infinity),
            preferredWidth: Double(preferredWidth), minimumTarget: FieldMonitorLayout.minimumTapTarget,
            scale: Double(scale))
    }
}

/// One native measurement owns the complete row: storage's original proposal, live link and real power.
public struct MonitorCompactTelemetryRow<Storage: View, Link: View, Power: View>: View {
    @Environment(\.displayScale) private var scale
    private let layout: FieldMonitorLayout
    private let safeArea: MonitorSafeArea
    private let metrics: MonitorTelemetryMetrics
    private let storage: () -> Storage
    private let link: () -> Link
    private let power: () -> Power
    private let minimumStatusTop: (CGFloat) -> Void

    public init(layout: FieldMonitorLayout, safeArea: MonitorSafeArea, metrics: MonitorTelemetryMetrics,
        @ViewBuilder storage: @escaping () -> Storage, @ViewBuilder link: @escaping () -> Link,
        @ViewBuilder power: @escaping () -> Power) {
        self.init(layout: layout, safeArea: safeArea, metrics: metrics, minimumStatusTop: { _ in },
            storage: storage, link: link, power: power)
    }

    public init(layout: FieldMonitorLayout, safeArea: MonitorSafeArea, metrics: MonitorTelemetryMetrics,
        minimumStatusTop: @escaping (CGFloat) -> Void, @ViewBuilder storage: @escaping () -> Storage,
        @ViewBuilder link: @escaping () -> Link, @ViewBuilder power: @escaping () -> Power) {
        self.layout = layout; self.safeArea = safeArea; self.metrics = metrics
        self.storage = storage; self.link = link; self.power = power
        self.minimumStatusTop = minimumStatusTop
    }

    public var body: some View {
        CompactTelemetryRowLayout(layout: layout, safeArea: safeArea, referenceLinkWidth: metrics.pillWidth,
            scale: Double(scale), powerHeight: metrics.pillHeight) {
            HStack(spacing: 0) { storage() }
            HStack(spacing: 0) { link() }.environment(\.monitorAdaptiveTelemetryPadding, true)
            HStack(spacing: 0) { power() }.environment(\.monitorAdaptiveTelemetryPadding, true)
        }
        .frame(width: layout.viewport.width, alignment: .leading)
        .background(GeometryReader { geometry in
            let extra = max(0, geometry.size.height - 48)
            let minimumTop = extra > 0 ? layout.telemetry.y - 13 + 24
                - layout.telemetry.height / 2 + metrics.pillHeight + extra + 8 : 0
            Color.clear.onChange(of: minimumTop, initial: true) { _, top in minimumStatusTop(top) }
        })
        .offset(y: layout.telemetry.y - 13)
    }
}

private struct CompactTelemetryRowLayout: Layout {
    let layout: FieldMonitorLayout
    let safeArea: MonitorSafeArea
    let referenceLinkWidth: Double
    let scale: Double
    let powerHeight: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let measured = frames(proposal: proposal, subviews: subviews)
        return CGSize(width: layout.viewport.width, height: 48 + (measured?.extraHeight ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let measured = frames(proposal: proposal, subviews: subviews) else { return }
        if measured.storage.width > 0 {
            subviews[0].place(at: CGPoint(x: bounds.minX + measured.budget.leading
                + measured.budget.storageWidth / 2, y: bounds.minY + 24), anchor: .center,
                proposal: ProposedViewSize(measured.storage))
        }
        subviews[1].place(at: CGPoint(x: bounds.minX + measured.budget.performanceX, y: bounds.minY + 24),
            anchor: .leading, proposal: ProposedViewSize(measured.link))
        subviews[2].place(at: CGPoint(x: bounds.minX + measured.budget.powerX,
            y: bounds.minY + 24 - layout.telemetry.height / 2 + (measured.budget.wrapsPower ? 56 : 0)),
            anchor: .topLeading, proposal: ProposedViewSize(measured.power))
    }

    private func frames(proposal: ProposedViewSize, subviews: Subviews) -> (
        storage: CGSize, link: CGSize, power: CGSize, budget: MonitorCompactTelemetryBudget, extraHeight: CGFloat
    )? {
        guard subviews.count == 3 else { return nil }
        let preferredLink = subviews[1].sizeThatFits(.unspecified)
        let legacyWidth = max(0, layout.telemetry.x - layout.status.x - 8
            - (preferredLink.width > 0 ? referenceLinkWidth : 0) - 8)
        let original = subviews[0].sizeThatFits(
            ProposedViewSize(width: legacyWidth, height: 48))
        let storage = CGSize(width: min(legacyWidth, original.width), height: original.height)
        let power = subviews[2].sizeThatFits(ProposedViewSize(
            width: layout.viewport.width - max(14, safeArea.leading) - max(14, safeArea.trailing), height: nil))
        let minimumLink = subviews[1].sizeThatFits(ProposedViewSize(width: 0, height: 48))
        let budget = MonitorCompactTelemetryBudget(layout: layout, safeLeading: safeArea.leading,
            safeTrailing: safeArea.trailing, storageWidth: Double(storage.width),
            powerWidth: Double(power.width), linkWidth: Double(preferredLink.width),
            minimumTarget: FieldMonitorLayout.minimumTapTarget, scale: scale,
            minimumLinkWidth: Double(minimumLink.width))
        let link = subviews[1].sizeThatFits(
            ProposedViewSize(width: budget.performanceWidth, height: 48))
        let extraHeight = (budget.wrapsPower ? 56 : 0) + max(0, power.height - powerHeight)
        return (storage, link, power, budget, extraHeight)
    }
}

/// Exact native pills wrap together when the declared values exceed the available line.
public struct MonitorTelemetryPowerLayout: Layout {
    public init() {}

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measured = arrangement(width: bounds.width, subviews: subviews)
        for (index, origin) in measured.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified)
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, usedWidth: CGFloat = 0
        var origins: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + 6; lineHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + 6; lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + lineHeight), origins)
    }
}
#endif
