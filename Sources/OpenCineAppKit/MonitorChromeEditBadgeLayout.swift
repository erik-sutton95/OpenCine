import Foundation

/// Where the Edit view puts each element's eye badge. Pure geometry so tests can
/// pin placement without a live monitor.
///
/// Badges sit **on** the control, on the side toward the canvas centre. Centering
/// them on an outer corner (then clamping 3 pt in) put rail / top-deck eyes in
/// the display corner radius, where they were clipped and untappable.
public enum MonitorChromeEditBadgeLayout {
    public static let badgeSize: CGFloat = 26
    public static let badgeGap: CGFloat = 4
    /// Hard inset from the physical canvas. 16 pt keeps a 26 pt eye inside the
    /// iPhone display corner curve (~52 pt).
    public static let edgeInset: CGFloat = 16
    /// How far a badge may peek past its element's edge. The rest sits on it.
    public static let overhang: CGFloat = 4

    public struct Box: Equatable, Sendable {
        public let section: MonitorDisplayChrome.Section
        public let frame: CGRect

        public init(section: MonitorDisplayChrome.Section, frame: CGRect) {
            self.section = section
            self.frame = frame
        }
    }

    public static func badgeFrames(
        _ boxes: [Box],
        viewport: CGSize,
        badgeSize: CGFloat = badgeSize
    ) -> [MonitorDisplayChrome.Section: CGRect] {
        let playable = playableRect(in: viewport, badgeSize: badgeSize)
        var placed: [CGRect] = []
        var result: [MonitorDisplayChrome.Section: CGRect] = [:]

        for box in boxes where box.frame.width > 1 && box.frame.height > 1 {
            let candidates = anchors(on: box.frame, viewport: viewport, badgeSize: badgeSize)
                .map { clamped($0, in: playable) }
            let choice =
                candidates.first { candidate in
                    !placed.contains { overlaps($0, candidate) }
                } ?? candidates[0]
            placed.append(choice)
            result[box.section] = choice
        }
        return result
    }

    public static func playableRect(in viewport: CGSize, badgeSize: CGFloat = badgeSize) -> CGRect {
        let inset = edgeInset
        let width = max(badgeSize, viewport.width - 2 * inset)
        let height = max(badgeSize, viewport.height - 2 * inset)
        let x = min(inset, max(0, viewport.width - width))
        let y = min(inset, max(0, viewport.height - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 4 corners + 4 mid-edges, badge mostly overlapping `frame`, inward first.
    private static func anchors(
        on frame: CGRect,
        viewport: CGSize,
        badgeSize: CGFloat
    ) -> [CGRect] {
        let preferTrailing = frame.midX < viewport.width / 2
        let preferBottom = frame.midY < viewport.height / 2
        return Anchor.allCases
            .sorted {
                rank($0, preferTrailing: preferTrailing, preferBottom: preferBottom)
                    < rank($1, preferTrailing: preferTrailing, preferBottom: preferBottom)
            }
            .map { $0.frame(on: frame, badgeSize: badgeSize, overhang: overhang) }
    }

    private enum Anchor: CaseIterable {
        case topLeading, top, topTrailing
        case leading, trailing
        case bottomLeading, bottom, bottomTrailing

        func frame(on box: CGRect, badgeSize: CGFloat, overhang: CGFloat) -> CGRect {
            let inner = badgeSize - overhang
            let midX = box.midX - badgeSize / 2
            let midY = box.midY - badgeSize / 2
            let x: CGFloat
            let y: CGFloat
            switch self {
            case .topLeading:
                x = box.minX - overhang
                y = box.minY - overhang
            case .top:
                x = midX
                y = box.minY - overhang
            case .topTrailing:
                x = box.maxX - inner
                y = box.minY - overhang
            case .leading:
                x = box.minX - overhang
                y = midY
            case .trailing:
                x = box.maxX - inner
                y = midY
            case .bottomLeading:
                x = box.minX - overhang
                y = box.maxY - inner
            case .bottom:
                x = midX
                y = box.maxY - inner
            case .bottomTrailing:
                x = box.maxX - inner
                y = box.maxY - inner
            }
            return CGRect(x: x, y: y, width: badgeSize, height: badgeSize)
        }
    }

    /// 0 = most inward (toward canvas centre), 4 = most outward (screen corner).
    private static func rank(
        _ anchor: Anchor,
        preferTrailing: Bool,
        preferBottom: Bool
    ) -> Int {
        let horizontal: Int
        switch anchor {
        case .topTrailing, .trailing, .bottomTrailing:
            horizontal = preferTrailing ? 0 : 2
        case .topLeading, .leading, .bottomLeading:
            horizontal = preferTrailing ? 2 : 0
        case .top, .bottom:
            horizontal = 1
        }
        let vertical: Int
        switch anchor {
        case .bottomLeading, .bottom, .bottomTrailing:
            vertical = preferBottom ? 0 : 2
        case .topLeading, .top, .topTrailing:
            vertical = preferBottom ? 2 : 0
        case .leading, .trailing:
            vertical = 1
        }
        return horizontal + vertical
    }

    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX + badgeGap && b.minX < a.maxX + badgeGap
            && a.minY < b.maxY + badgeGap && b.minY < a.maxY + badgeGap
    }

    private static func clamped(_ frame: CGRect, in playable: CGRect) -> CGRect {
        guard playable.width >= frame.width, playable.height >= frame.height else {
            return CGRect(
                x: playable.minX, y: playable.minY, width: frame.width, height: frame.height)
        }
        return CGRect(
            x: min(max(frame.minX, playable.minX), playable.maxX - frame.width),
            y: min(max(frame.minY, playable.minY), playable.maxY - frame.height),
            width: frame.width,
            height: frame.height
        )
    }
}
