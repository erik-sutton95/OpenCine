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
        if let stars {
            VStack(spacing: 4) {
                Button { withAnimation(.spring(duration: 0.28)) { expanded.toggle() } } label: {
                    HStack(spacing: 3) {
                        MonitorIcon.star.view(filled: true).frame(width: 10, height: 10)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }.foregroundStyle(MonitorTheme.muted).frame(width: 52, height: 20)
                        .liquidGlass(in: Capsule(), interactive: true).opacity(0.9)
                }.buttonStyle(.monitorTapTarget)
                    .accessibilityLabel(expanded ? "Hide star rating" : "Show star rating")
                    .accessibilityIdentifier("monitor.playback.rating")
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
