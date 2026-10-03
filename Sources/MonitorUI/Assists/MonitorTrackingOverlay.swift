#if os(iOS)
import SwiftUI

/// Current marks expressed in normalized picture coordinates, after source-axis projection.
public struct MonitorTrackingBracketValue {
    public let normalizedRect: CGRect
    public let color: Color
    public let lineWidth: CGFloat
    public init(normalizedRect: CGRect, color: Color, lineWidth: CGFloat = 2) {
        self.normalizedRect = normalizedRect; self.color = color; self.lineWidth = lineWidth
    }
}

public struct MonitorFocusMark {
    public let point: CGPoint
    public let color: Color
    public let aeLocked: Bool
    public let focusLocked: Bool
    public init(point: CGPoint, color: Color, aeLocked: Bool = false, focusLocked: Bool = false) {
        self.point = point; self.color = color; self.aeLocked = aeLocked; self.focusLocked = focusLocked
    }
}

/// Native drawing receives resolved marks; it chooses no camera tracking or focus policy.
public struct MonitorTrackingLayer: View {
    private let brackets: [MonitorTrackingBracketValue]
    private let focus: MonitorFocusMark?
    private let feed: CGRect
    public init(brackets: [MonitorTrackingBracketValue], focus: MonitorFocusMark? = nil, feed: CGRect) {
        self.brackets = brackets; self.focus = focus; self.feed = feed
    }
    public var body: some View {
        ZStack {
            MonitorSnapshotRows(Array(brackets.enumerated()), id: \.offset) { _, mark in
                MonitorTrackingBracketView(rect: MonitorTrackingGeometry.feedRect(normalized: mark.normalizedRect, in: feed),
                    color: mark.color, lineWidth: mark.lineWidth)
            }
            if let focus {
                MonitorFocusBoxView(feed: feed, normalized: focus.point, aeLocked: focus.aeLocked,
                    focusLocked: focus.focusLocked, color: focus.color)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

public struct MonitorTrackingCancelButton: View {
    private let color: Color
    private let ink: Color
    private let action: () -> Void
    public init(color: Color, ink: Color = MonitorTheme.canvas, action: @escaping () -> Void) {
        self.color = color; self.ink = ink; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            MonitorIcon.x.frame(width: 11, height: 11).foregroundStyle(ink)
                .frame(width: MonitorTrackingGeometry.cancelSize, height: MonitorTrackingGeometry.cancelSize)
                .background(color, in: Circle())
        }.buttonStyle(MonitorSettingsButtonStyle())
            .accessibilityLabel("Stop subject tracking").accessibilityIdentifier("monitor.system.trackCancel")
    }
}

public enum MonitorTrackingGeometry {
    public static let focusBoxSideFraction: CGFloat = 0.14
    public static func feedRect(normalized: CGRect, in feed: CGRect) -> CGRect {
        CGRect(x: feed.minX + normalized.minX * feed.width, y: feed.minY + normalized.minY * feed.height,
            width: max(1, normalized.width * feed.width), height: max(1, normalized.height * feed.height))
    }
    public static func cancelRect(for rect: CGRect) -> CGRect {
        CGRect(x: rect.maxX - cancelHitSize / 2, y: rect.minY - cancelHitSize / 2,
            width: cancelHitSize, height: cancelHitSize)
    }
    public static let cancelSize: CGFloat = 28
    /// The visible disc is 28 points; its input target remains 44 points.
    public static let cancelHitSize: CGFloat = 44

    public static func cornerRadius(for rect: CGRect) -> CGFloat {
        min(MonitorTheme.radius, max(6, min(rect.width, rect.height) * 0.12))
    }

    /// Corner-bracket arm. Leaves a gap ≥ 25% of the side so it reads as a
    /// traditional tracking box, not a closed frame.
    public static func bracketArm(along length: CGFloat) -> CGFloat {
        let proposed = length * 0.26
        let minGap = max(8, length * 0.28)
        return min(max(10, proposed), max(10, (length - minGap) / 2))
    }

    public static func bracketPath(in size: CGSize) -> Path {
        let w = size.width
        let h = size.height
        let ax = bracketArm(along: w)
        let ay = bracketArm(along: h)
        let r = min(
            cornerRadius(for: CGRect(origin: .zero, size: size)),
            max(0, ax - 1),
            max(0, ay - 1)
        )
        var path = Path()
        path.move(to: CGPoint(x: 0, y: ay))
        path.addLine(to: CGPoint(x: 0, y: r))
        if r >= 3 {
            path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
        } else {
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: r, y: 0))
        }
        path.addLine(to: CGPoint(x: ax, y: 0))
        path.move(to: CGPoint(x: w - ax, y: 0))
        path.addLine(to: CGPoint(x: w - r, y: 0))
        if r >= 3 {
            path.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
        } else {
            path.addLine(to: CGPoint(x: w, y: 0))
            path.addLine(to: CGPoint(x: w, y: r))
        }
        path.addLine(to: CGPoint(x: w, y: ay))
        path.move(to: CGPoint(x: w, y: h - ay))
        path.addLine(to: CGPoint(x: w, y: h - r))
        if r >= 3 {
            path.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
        } else {
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: w - r, y: h))
        }
        path.addLine(to: CGPoint(x: w - ax, y: h))
        path.move(to: CGPoint(x: ax, y: h))
        path.addLine(to: CGPoint(x: r, y: h))
        if r >= 3 {
            path.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
        } else {
            path.addLine(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: 0, y: h - r))
        }
        path.addLine(to: CGPoint(x: 0, y: h - ay))
        return path
    }
}

private struct MonitorTrackingBracketView: View {
    let rect: CGRect
    let color: Color
    var lineWidth: CGFloat = 2

    var body: some View {
        MonitorTrackingGeometry.bracketPath(in: rect.size)
            .stroke(
                color,
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
            .shadow(color: .black.opacity(0.55), radius: 1)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct MonitorFocusBoxView: View {
    let feed: CGRect
    let normalized: CGPoint
    let aeLocked: Bool
    let focusLocked: Bool
    let color: Color

    var body: some View {
        let side = min(feed.width, feed.height) * MonitorTrackingGeometry.focusBoxSideFraction
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let x = feed.minX + normalized.x * feed.width
        let y = feed.minY + normalized.y * feed.height
        // The tag sits right of the box, or left when the box is near the right edge.
        let tagLeading = x + side / 2 + 26 > feed.maxX
        ZStack {
            RoundedRectangle(
                cornerRadius: MonitorTrackingGeometry.cornerRadius(for: rect), style: .continuous
            )
            .stroke(color, lineWidth: 1.5)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .frame(width: side, height: side)
            .position(x: x, y: y)
            if aeLocked {
                Text("AE-L")
                    .font(MonitorTheme.font(9, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(color)
                    .shadow(color: .black.opacity(0.8), radius: 1.5, y: 0.5)
                    .fixedSize()
                    .position(
                        x: tagLeading ? x - side / 2 - 14 : x + side / 2 + 14, y: y - side / 2 + 6)
            }
            if focusLocked {
                MonitorIcon.lock
                    .frame(width: 10, height: 10)
                    .foregroundStyle(color)
                    .shadow(color: .black.opacity(0.8), radius: 1.5, y: 0.5)
                    .position(
                        x: tagLeading ? x - side / 2 - 10 : x + side / 2 + 10, y: y + side / 2 - 6)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
