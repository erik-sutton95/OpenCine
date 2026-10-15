#if os(iOS)
    import SwiftUI

    /// Source-resolved picture attitude. Freshness and picture-axis transforms stay in the source adapter.
    public enum MonitorLevelDisplay: Equatable, Sendable {
        case unavailable
        case gauges(rollDeg: Double, tiltDeg: Double)
        case bubble(xDeg: Double, yDeg: Double)
        /// A horizon line through the picture's centre, rotated by the roll (a camera that
        /// declares the `MonitorLevelStyle.horizon` style).
        case horizon(rollDeg: Double)
    }

    public enum MonitorLevelGeometry {
        public static let rollLiftLandscape: CGFloat = 84
        public static let rollLiftPortrait: CGFloat = 22

        /// Point-space strips on the visible picture, kept clear of portrait/landscape chrome.
        @MainActor public static func frames(feed: CGRect, viewport: CGRect, portrait: Bool) -> (
            roll: CGRect, tilt: CGRect
        ) {
            var visible = feed.intersection(viewport)
            if visible.isNull || visible.isEmpty { visible = feed }
            let t = MonitorLevelGauge.thickness
            let rollWidth = max(0, min(MonitorLevelGauge.maxLength, visible.width - 24))
            let rollMidY = visible.maxY - (portrait ? rollLiftPortrait : rollLiftLandscape)
            let tiltHeight = max(0, min(MonitorLevelGauge.maxLength, visible.height - 12))
            let tiltMidX = min(visible.midX + (rollMidY - visible.midY), visible.maxX - 6 - t / 2)
            return (
                CGRect(
                    x: visible.midX - rollWidth / 2, y: rollMidY - t / 2, width: rollWidth,
                    height: t),
                CGRect(
                    x: tiltMidX - t / 2, y: visible.midY - tiltHeight / 2, width: t,
                    height: tiltHeight)
            )
        }

        public static func accessibilityValue(
            _ display: MonitorLevelDisplay, noDataLabel: String = "No level data"
        ) -> String {
            switch display {
            case .unavailable: noDataLabel
            case .gauges(let roll, let tilt): String(format: "Roll %+.1f°, tilt %+.1f°", roll, tilt)
            case .bubble(let x, let y): String(format: "Off plumb %+.1f° / %+.1f°", x, y)
            case .horizon(let roll): String(format: "Horizon roll %+.1f°", roll)
            }
        }
    }

    /// Actual strip/bubble assembly; receives a current display value and owns no refresh clock.
    public struct MonitorLevelOverlay: View {
        private let display: MonitorLevelDisplay
        private let feed: CGRect
        private let viewport: CGRect
        private let portrait: Bool
        private let noDataLabel: String

        public init(
            display: MonitorLevelDisplay, feed: CGRect, viewport: CGRect, portrait: Bool,
            noDataLabel: String = "No level data"
        ) {
            self.display = display
            self.feed = feed
            self.viewport = viewport
            self.portrait = portrait
            self.noDataLabel = noDataLabel
        }

        public var body: some View {
            content(display)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Level")
                .accessibilityValue(
                    MonitorLevelGeometry.accessibilityValue(display, noDataLabel: noDataLabel)
                )
                .accessibilityIdentifier("monitor.level")
                .allowsHitTesting(false)
        }

        @ViewBuilder
        private func content(_ mode: MonitorLevelDisplay) -> some View {
            let frames = MonitorLevelGeometry.frames(
                feed: feed, viewport: viewport, portrait: portrait)
            switch mode {
            case .bubble(let x, let y):
                let visible =
                    feed.intersection(viewport).isNull ? feed : feed.intersection(viewport)
                MonitorLevelBubble(xDeg: x, yDeg: y)
                    .position(x: visible.midX, y: visible.midY)
            case .horizon(let roll):
                MonitorLevelHorizon(rollDeg: roll)
                    .position(x: feed.midX, y: feed.midY)
            case .gauges(let roll, let tilt):
                strips(roll: roll, tilt: tilt, frames: frames, caption: nil)
            case .unavailable:
                strips(roll: nil, tilt: nil, frames: frames, caption: noDataLabel)
            }
        }

        private func strips(
            roll: Double?, tilt: Double?, frames: (roll: CGRect, tilt: CGRect), caption: String?
        )
            -> some View
        {
            ZStack {
                MonitorLevelGauge(axis: .horizontal, value: roll)
                    .frame(width: frames.roll.width, height: frames.roll.height)
                    .position(x: frames.roll.midX, y: frames.roll.midY)
                if let caption {
                    MonitorLevelCaption(text: caption)
                        .position(x: frames.roll.midX, y: frames.roll.maxY + 6)
                }
                if !frames.tilt.isEmpty {
                    MonitorLevelGauge(axis: .vertical, value: tilt)
                        .frame(width: frames.tilt.width, height: frames.tilt.height)
                        .position(x: frames.tilt.midX, y: frames.tilt.midY)
                }
            }
        }
    }

    /// Two wings around a centre ring, rotating with the roll; green when level.
    struct MonitorLevelHorizon: View {
        /// Kotlin `MonitorLevelGeometry.HORIZON_THRESHOLD`.
        static let levelDeg = 0.8
        let rollDeg: Double

        var body: some View {
            let level = abs(rollDeg) < Self.levelDeg
            let good = MonitorTheme.edrSRGB(
                red: 0.18, green: 0.78, blue: 0.42, gain: MonitorTheme.hdrGain)
            let color = level ? good : MonitorTheme.accent
            HStack(spacing: 10) {
                Capsule().fill(color).frame(width: 64, height: 2)
                Circle().stroke(color, lineWidth: 1.6).frame(width: 10, height: 10)
                Capsule().fill(color).frame(width: 64, height: 2)
            }
            .rotationEffect(.degrees(rollDeg))
            .animation(.easeOut(duration: 0.18), value: level)
        }
    }

    private struct MonitorLevelCaption: View {
        let text: String

        var body: some View {
            Text(text)
                .font(MonitorTheme.font(8, weight: .medium))
                .kerning(0.5)
                .foregroundStyle(MonitorTheme.muted)
                .shadow(color: .black.opacity(0.6), radius: 1.5)
                .fixedSize()
        }
    }

#endif
