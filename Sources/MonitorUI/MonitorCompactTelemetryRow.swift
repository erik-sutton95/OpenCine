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

    public init(layout: FieldMonitorLayout, safeArea: MonitorSafeArea, metrics: MonitorTelemetryMetrics,
        @ViewBuilder storage: @escaping () -> Storage, @ViewBuilder link: @escaping () -> Link,
        @ViewBuilder power: @escaping () -> Power) {
        self.layout = layout; self.safeArea = safeArea; self.metrics = metrics
        self.storage = storage; self.link = link; self.power = power
    }

    public var body: some View {
        CompactTelemetryRowLayout(layout: layout, safeArea: safeArea, referenceLinkWidth: metrics.pillWidth,
            scale: Double(scale)) {
            HStack(spacing: 0) { storage() }
            HStack(spacing: 0) { link() }.environment(\.monitorAdaptiveTelemetryPadding, true)
            HStack(spacing: 0) { power() }
        }
        .frame(width: layout.viewport.width, height: 48, alignment: .leading)
        .offset(y: layout.telemetry.y - 13)
    }
}

private struct CompactTelemetryRowLayout: Layout {
    let layout: FieldMonitorLayout
    let safeArea: MonitorSafeArea
    let referenceLinkWidth: Double
    let scale: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let measured = frames(proposal: proposal, subviews: subviews)
        return CGSize(width: layout.viewport.width,
            height: max(proposal.height ?? 0, 44, measured?.storage.height ?? 0,
                measured?.link.height ?? 0, measured?.power.height ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let measured = frames(proposal: proposal, subviews: subviews) else { return }
        if measured.storage.width > 0 {
            subviews[0].place(at: CGPoint(x: bounds.minX + measured.budget.leading
                + measured.budget.storageWidth / 2, y: bounds.midY), anchor: .center,
                proposal: ProposedViewSize(measured.storage))
        }
        subviews[1].place(at: CGPoint(x: bounds.minX + measured.budget.performanceX, y: bounds.midY),
            anchor: .leading, proposal: ProposedViewSize(measured.link))
        subviews[2].place(at: CGPoint(x: bounds.minX + measured.budget.powerX,
            y: bounds.midY - layout.telemetry.height / 2),
            anchor: .topLeading, proposal: ProposedViewSize(measured.power))
    }

    private func frames(proposal: ProposedViewSize, subviews: Subviews) -> (
        storage: CGSize, link: CGSize, power: CGSize, budget: MonitorCompactTelemetryBudget
    )? {
        guard subviews.count == 3 else { return nil }
        let preferredLink = subviews[1].sizeThatFits(.unspecified)
        let legacyWidth = max(0, layout.telemetry.x - layout.status.x - 8
            - (preferredLink.width > 0 ? referenceLinkWidth : 0) - 8)
        let original = subviews[0].sizeThatFits(
            ProposedViewSize(width: legacyWidth, height: proposal.height))
        let storage = CGSize(width: min(legacyWidth, original.width), height: original.height)
        let power = subviews[2].sizeThatFits(.unspecified)
        let budget = MonitorCompactTelemetryBudget(layout: layout, safeLeading: safeArea.leading,
            safeTrailing: safeArea.trailing, storageWidth: Double(storage.width),
            powerWidth: Double(power.width), linkWidth: Double(preferredLink.width),
            minimumTarget: FieldMonitorLayout.minimumTapTarget, scale: scale)
        let link = subviews[1].sizeThatFits(
            ProposedViewSize(width: budget.performanceWidth, height: proposal.height))
        return (storage, link, power, budget)
    }
}
#endif
