#if os(iOS)
import MonitorPresentation
import SwiftUI

/// A reported star rating; tapping the current level requests clearing it.
public struct MonitorStarRating: View {
    private let stars: Int
    private let levels: [Int]
    private let enabled: Bool
    private let select: (Int) -> Void
    private let identifierPrefix: String
    public init(stars: Int, levels: [Int] = [1, 2, 3, 4, 5], enabled: Bool = true,
        identifierPrefix: String = "monitor.photo.rating", select: @escaping (Int) -> Void) {
        self.stars = stars; self.levels = levels; self.enabled = enabled; self.select = select
        self.identifierPrefix = identifierPrefix
    }
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(levels, id: \.self) { level in
                Button { select(level == stars ? 0 : level) } label: {
                    MonitorIcon.star.view(filled: level <= stars).frame(width: 22, height: 22)
                        .foregroundStyle(level <= stars ? MonitorTheme.accent : MonitorTheme.muted)
                        .frame(width: 44, height: 44)
                }.buttonStyle(.monitorTapTarget).disabled(!enabled)
                    .accessibilityLabel(MonitorPlaybackCopy.rate(level))
                    .accessibilityIdentifier("\(identifierPrefix).\(level)")
            }
        }.padding(.horizontal, 4).padding(.vertical, 2).liquidGlass(in: Capsule())
    }
}
#endif
