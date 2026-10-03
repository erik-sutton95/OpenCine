#if os(iOS)
import SwiftUI

public enum MonitorGuideFamily: String, CaseIterable, Codable, Sendable, Identifiable {
    case film = "Film"
    case social = "Social"
    public var id: String { rawValue }
}

public enum MonitorGuideAspect: String, CaseIterable, Identifiable, Codable, Sendable {
    case cinema276 = "2.76:1"
    case cinema = "2.39:1"
    case cinema235 = "2.35:1"
    case twoK = "2.00:1"
    case wide = "1.85:1"
    case hd = "16:9"
    case euro = "1.66:1"
    case imax = "1.43:1"
    case academy = "4:3"
    case vertical = "9:16"
    case social = "4:5"
    case square = "1:1"
    case portrait = "2:3"
    case feed = "1.91:1"

    public var id: String { rawValue }

    public var ratio: CGFloat {
        let parts = rawValue.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return 1 }
        return CGFloat(parts[0] / parts[1])
    }

    public static func ratios(for family: MonitorGuideFamily) -> [MonitorGuideAspect] {
        switch family {
        case .film: [.cinema276, .cinema, .cinema235, .twoK, .wide, .hd, .euro, .imax, .academy]
        case .social: [.vertical, .social, .square, .portrait, .hd, .feed]
        }
    }
}

public enum MonitorGridOption: String, CaseIterable, Identifiable, Sendable {
    case thirds = "Thirds"
    case phi = "Phi Grid"
    case diagonal = "Diagonal"

    public var id: String { rawValue }
}

public struct MonitorGridSegment: Equatable, Sendable {
    public let from: CGPoint
    public let to: CGPoint
    public init(from: CGPoint, to: CGPoint) { self.from = from; self.to = to }
}
public enum MonitorGridGeometry {
    public static let thirdsFractions: [CGFloat] = [1.0 / 3, 2.0 / 3]
    public static let phiFractions: [CGFloat] = [0.382, 0.618]
    public static func segments(
        in feed: CGRect,
        thirds: Bool,
        phi: Bool,
        diagonal: Bool
    ) -> [MonitorGridSegment] {
        var lines: [MonitorGridSegment] = []
        if thirds { appendFractions(feed, thirdsFractions, to: &lines) }
        if phi { appendFractions(feed, phiFractions, to: &lines) }
        if diagonal {
            lines.append(
                MonitorGridSegment(
                    from: CGPoint(x: feed.minX, y: feed.minY),
                    to: CGPoint(x: feed.maxX, y: feed.maxY)
                )
            )
            lines.append(
                MonitorGridSegment(
                    from: CGPoint(x: feed.maxX, y: feed.minY),
                    to: CGPoint(x: feed.minX, y: feed.maxY)
                )
            )
        }
        return lines
    }
    private static func appendFractions(
        _ feed: CGRect,
        _ fractions: [CGFloat],
        to lines: inout [MonitorGridSegment]
    ) {
        for fraction in fractions {
            let x = feed.minX + feed.width * fraction
            let y = feed.minY + feed.height * fraction
            lines.append(
                MonitorGridSegment(
                    from: CGPoint(x: x, y: feed.minY),
                    to: CGPoint(x: x, y: feed.maxY)
                )
            )
            lines.append(
                MonitorGridSegment(
                    from: CGPoint(x: feed.minX, y: y),
                    to: CGPoint(x: feed.maxX, y: y)
                )
            )
        }
    }
}
public enum MonitorGuideGeometry {
    public static func rectForRatio(_ feed: CGRect, _ ratio: CGFloat) -> CGRect {
        let width: CGFloat
        let height: CGFloat
        if feed.width / feed.height > ratio {
            height = feed.height
            width = feed.height * ratio
        } else {
            width = feed.width
            height = feed.width / ratio
        }
        return CGRect(
            x: feed.minX + (feed.width - width) / 2,
            y: feed.minY + (feed.height - height) / 2,
            width: width,
            height: height
        )
    }
}

public struct MonitorFeedGrid: View {
    let feed: CGRect
    var thirds = true
    var phi = false
    var diagonal = false

    public init(feed: CGRect, thirds: Bool = true, phi: Bool = false, diagonal: Bool = false) {
        self.feed = feed; self.thirds = thirds; self.phi = phi; self.diagonal = diagonal
    }
    public var body: some View {
        Path { path in
            for segment in MonitorGridGeometry.segments(in: feed, thirds: thirds, phi: phi, diagonal: diagonal) {
                path.move(to: segment.from); path.addLine(to: segment.to)
            }
        }
        .stroke(Color.white.opacity(0.22), lineWidth: 1)
    }

}

public struct MonitorFeedCrosshair: View {
    let feed: CGRect

    public init(feed: CGRect) { self.feed = feed }
    public var body: some View {
        ZStack {
            Rectangle().fill(Color.white.opacity(0.65)).frame(width: 1.4, height: 40)
            Rectangle().fill(Color.white.opacity(0.65)).frame(width: 40, height: 1.4)
        }
        .position(x: feed.midX, y: feed.midY)
    }
}

public struct MonitorFeedComparisonMarks: View {
    let vertical: Bool
    let feed: CGRect

    let originalLabel: String
    let processedLabel: String
    public init(vertical: Bool, feed: CGRect, originalLabel: String = "LOG", processedLabel: String = "LUT") {
        self.vertical = vertical; self.feed = feed
        self.originalLabel = originalLabel; self.processedLabel = processedLabel
    }
    public var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.5))
                .frame(width: vertical ? 1 : feed.width, height: vertical ? feed.height : 1)
                .position(x: feed.midX, y: feed.midY)
            label(originalLabel)
                .position(
                    x: vertical ? feed.midX - 16 : feed.minX + feed.width * 0.16,
                    y: vertical ? feed.minY + feed.height * 0.16 : feed.midY - 10)
            label(processedLabel)
                .position(
                    x: vertical ? feed.midX + 16 : feed.minX + feed.width * 0.16,
                    y: vertical ? feed.minY + feed.height * 0.16 : feed.midY + 10)
        }
        .allowsHitTesting(false)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(MonitorTheme.font(8, weight: .semibold)).monospacedDigit()
            .kerning(0.5)
            .foregroundStyle(Color.white.opacity(0.85))
            .shadow(color: .black.opacity(0.8), radius: 1.5, y: 0.5)
    }
}

private struct GuideFrame: Identifiable {
    let ratio: MonitorGuideAspect
    let rect: CGRect
    var id: String { ratio.rawValue }
}

public struct MonitorAspectGuideFrames: View {
    let selectedRatios: Set<MonitorGuideAspect>
    var maskEnabled = false
    let feed: CGRect

    public init(selectedRatios: Set<MonitorGuideAspect>, maskEnabled: Bool = false, feed: CGRect) {
        self.selectedRatios = selectedRatios; self.maskEnabled = maskEnabled; self.feed = feed
    }
    public var body: some View {
        let frames =
            selectedRatios
            .sorted { $0.ratio < $1.ratio }
            .map { GuideFrame(ratio: $0, rect: MonitorGuideGeometry.rectForRatio(feed, $0.ratio)) }
        ZStack {
            if maskEnabled, !frames.isEmpty {
                Canvas { context, _ in
                    context.fill(Path(feed), with: .color(.black.opacity(0.6)))
                    context.blendMode = .destinationOut
                    for frame in frames {
                        context.fill(Path(frame.rect), with: .color(.black))
                    }
                }
            }
            MonitorSnapshotRows(frames) { frame in
                Rectangle()
                    .stroke(MonitorTheme.accent.opacity(0.85), lineWidth: 1)
                    .frame(width: frame.rect.width, height: frame.rect.height)
                    .position(x: frame.rect.midX, y: frame.rect.midY)
                Text(frame.ratio.rawValue)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .kerning(1.2)
                    .foregroundStyle(MonitorTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 5))
                    .fixedSize()
                    .position(x: frame.rect.minX, y: frame.rect.minY)
                    .offset(x: 34, y: 13)
            }
        }
    }
}
#endif
