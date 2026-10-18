#if os(iOS)
import MonitorPresentation
import SwiftUI

/// A reported rating stays out of the picture until the operator opens its shade.
public struct MonitorPlaybackRatingShade: View {
    private let stars: Int?
    private let levels: [Int]
    private let enabled: Bool
    private let notice: String?
    private let select: (Int) -> Void
    @Binding private var expanded: Bool
    public init(stars: Int?, levels: [Int], enabled: Bool, notice: String?, expanded: Binding<Bool>,
        select: @escaping (Int) -> Void) {
        self.stars = stars; self.levels = levels; self.enabled = enabled; self.notice = notice
        _expanded = expanded; self.select = select
    }
    public var body: some View {
        VStack(spacing: 4) {
            MonitorPlaybackRatingAnchor(stars: stars, expanded: $expanded)
            MonitorPlaybackRatingDetails(stars: stars, levels: levels, enabled: enabled,
                notice: notice, expanded: expanded, select: select)
        }
    }
}

/// The compact rating control fits the playback action row without widening when opened.
public struct MonitorPlaybackRatingAnchor: View {
    private let stars: Int?
    @Binding private var expanded: Bool
    public init(stars: Int?, expanded: Binding<Bool>) {
        self.stars = stars; _expanded = expanded
    }
    public var body: some View {
        if stars != nil {
            Button { withAnimation(.spring(duration: 0.28)) { expanded.toggle() } } label: {
                HStack(spacing: 3) {
                    MonitorIcon.star.view(filled: true).frame(width: 10, height: 10)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }.foregroundStyle(MonitorTheme.muted).frame(width: 52, height: 44)
                    .liquidGlass(in: Capsule(), interactive: true).opacity(0.9)
            }.buttonStyle(.monitorTapTarget)
                .accessibilityLabel(MonitorPlaybackCopy.rating(expanded: expanded))
                .accessibilityIdentifier("monitor.playback.rating")
        }
    }
}

/// Expanded choices remain in the measured header, with complete native touch bounds.
public struct MonitorPlaybackRatingDetails: View {
    private let stars: Int?
    private let levels: [Int]
    private let enabled: Bool
    private let notice: String?
    private let expanded: Bool
    private let select: (Int) -> Void
    public init(stars: Int?, levels: [Int], enabled: Bool, notice: String?, expanded: Bool,
        select: @escaping (Int) -> Void) {
        self.stars = stars; self.levels = levels; self.enabled = enabled; self.notice = notice
        self.expanded = expanded; self.select = select
    }
    public var body: some View {
        if let stars {
            VStack(alignment: .trailing, spacing: 4) {
                if expanded {
                    MonitorStarRating(stars: stars, levels: levels, enabled: enabled,
                        identifierPrefix: "monitor.playback.rating", select: select)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let notice { Text(notice).font(MonitorTheme.font(12)).foregroundStyle(MonitorTheme.text)
                    .padding(8).liquidGlass(in: Capsule()).accessibilityIdentifier("monitor.playback.rating.notice") }
            }
        }
    }
}
#endif
