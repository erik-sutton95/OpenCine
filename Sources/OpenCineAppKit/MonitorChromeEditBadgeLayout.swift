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
    /// The square a badge is hit across, centred on it (`ChromeEditBadge`'s `minTapTarget()`).
    /// No two badges' touch targets overlap.
    public static let touchTarget: CGFloat = 44

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
        badgeSize: CGFloat = badgeSize,
        touchTarget: CGFloat = touchTarget
    ) -> [MonitorDisplayChrome.Section: CGRect] {
        badgeFrames(
            keyed: boxes.map { ($0.section, $0.frame) }, viewport: viewport, badgeSize: badgeSize,
            touchTarget: touchTarget)
    }

    /// The same placement for an app's own chrome sections. `boxes` order is the placement
    /// priority; unmeasured (zero-sized) boxes get no badge.
    public static func badgeFrames<Key: Hashable>(
        keyed boxes: [(key: Key, frame: CGRect)],
        viewport: CGSize,
        badgeSize: CGFloat = badgeSize,
        touchTarget: CGFloat = touchTarget
    ) -> [Key: CGRect] {
        let playable = playableRect(in: viewport, badgeSize: badgeSize)
        // Origin-to-origin distance two badges keep along at least one axis.
        let spacing = max(badgeSize + badgeGap, touchTarget)
        let measured = boxes.filter { $0.frame.width > 1 && $0.frame.height > 1 }
        var placed: [CGRect] = []
        var result: [Key: CGRect] = [:]

        for box in measured {
            let ranked = rankedAnchors(on: box.frame, viewport: viewport)
            let candidates = ranked.map {
                clamped(
                    $0.frame(on: box.frame, badgeSize: badgeSize, overhang: overhang), in: playable)
            }
            let free = candidates.first { candidate in
                !placed.contains { overlaps($0, candidate, spacing: spacing) }
            }
            // Crowded: a box nested in another chrome box is badged only where its own eye fits;
            // any other box takes the nearest free spot outward from its best anchor.
            let nested = measured.contains { other in
                other.key != box.key && other.frame != box.frame && encloses(other.frame, box.frame)
            }
            let choice: CGRect?
            if let free {
                choice = free
            } else if nested {
                choice = nil
            } else {
                choice =
                    stackOutward(
                        from: ranked[0], start: candidates[0], playable: playable, placed: placed,
                        spacing: spacing) ?? candidates[0]
            }
            guard let choice else { continue }
            placed.append(choice)
            result[box.key] = choice
        }
        return result
    }

    /// The nearest free spot outward from `anchor`'s `start` inside `playable`: along each
    /// outward axis the badge slides just past every badge it meets, and the shorter slide wins
    /// (vertical on a tie).
    private static func stackOutward(
        from anchor: Anchor, start: CGRect, playable: CGRect, placed: [CGRect], spacing: CGFloat
    ) -> CGRect? {
        let dx: CGFloat
        switch anchor {
        case .topLeading, .leading, .bottomLeading: dx = -1
        case .topTrailing, .trailing, .bottomTrailing: dx = 1
        case .top, .bottom: dx = 0
        }
        let dy: CGFloat
        switch anchor {
        case .topLeading, .top, .topTrailing: dy = -1
        case .bottomLeading, .bottom, .bottomTrailing: dy = 1
        case .leading, .trailing: dy = 0
        }
        var axes: [(x: CGFloat, y: CGFloat)] = []
        if dy != 0 { axes.append((0, dy)) }
        if dx != 0 { axes.append((dx, 0)) }
        var best: CGRect?
        for axis in axes {
            guard
                let frame = slide(
                    start, x: axis.x, y: axis.y, playable: playable, placed: placed,
                    spacing: spacing)
            else { continue }
            let moved = abs(frame.minX - start.minX) + abs(frame.minY - start.minY)
            if let current = best,
                abs(current.minX - start.minX) + abs(current.minY - start.minY) <= moved
            {
                continue
            }
            best = frame
        }
        return best
    }

    /// `start` moved along (`x`, `y`) just past every placed badge it meets; nil once it leaves
    /// `playable`.
    private static func slide(
        _ start: CGRect, x ux: CGFloat, y uy: CGFloat, playable: CGRect, placed: [CGRect],
        spacing: CGFloat
    ) -> CGRect? {
        var frame = start
        while true {
            let hit = placed.filter { overlaps($0, frame, spacing: spacing) }
            if hit.isEmpty { return frame }
            var next = frame
            if uy != 0 {
                next.origin.y =
                    uy > 0
                    ? hit.map(\.minY).max()! + spacing : hit.map(\.minY).min()! - spacing
            } else {
                next.origin.x =
                    ux > 0
                    ? hit.map(\.minX).max()! + spacing : hit.map(\.minX).min()! - spacing
            }
            if (next.minX - frame.minX) * ux + (next.minY - frame.minY) * uy <= 0 { return nil }
            if next.minX < playable.minX || next.minY < playable.minY
                || next.maxX > playable.maxX || next.maxY > playable.maxY
            {
                return nil
            }
            frame = next
        }
    }

    private static func encloses(_ outer: CGRect, _ inner: CGRect) -> Bool {
        outer.minX <= inner.minX && outer.minY <= inner.minY && inner.maxX <= outer.maxX
            && inner.maxY <= outer.maxY
    }

    public static func playableRect(in viewport: CGSize, badgeSize: CGFloat = badgeSize) -> CGRect {
        let inset = edgeInset
        let width = max(badgeSize, viewport.width - 2 * inset)
        let height = max(badgeSize, viewport.height - 2 * inset)
        let x = min(inset, max(0, viewport.width - width))
        let y = min(inset, max(0, viewport.height - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 4 corners + 4 mid-edges, inward first; ties keep `Anchor.allCases` order.
    private static func rankedAnchors(on frame: CGRect, viewport: CGSize) -> [Anchor] {
        let preferTrailing = frame.midX < viewport.width / 2
        let preferBottom = frame.midY < viewport.height / 2
        return Anchor.allCases.enumerated()
            .sorted { lhs, rhs in
                let left = rank(
                    lhs.element, preferTrailing: preferTrailing, preferBottom: preferBottom)
                let right = rank(
                    rhs.element, preferTrailing: preferTrailing, preferBottom: preferBottom)
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
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

    /// Two badge-sized frames closer than `spacing` on both axes: their touch targets (or discs
    /// and gap) meet.
    private static func overlaps(_ a: CGRect, _ b: CGRect, spacing: CGFloat) -> Bool {
        abs(a.minX - b.minX) < spacing - spacingSlack
            && abs(a.minY - b.minY) < spacing - spacingSlack
    }

    /// Badges exactly `spacing` apart touch; rounding of a slid origin must not read as a
    /// collision.
    private static let spacingSlack: CGFloat = 0.01

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
