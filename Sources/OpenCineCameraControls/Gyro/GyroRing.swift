import Foundation
import OpenCineGyro

/// What the calibration ring draws for one phase. Platform neutral so it is testable anywhere;
/// the Android ring reads the same values.
public struct GyroRingModel: Equatable, Sendable {
    /// Fraction of the 60 ticks lit in the accent, clockwise from 12 o'clock.
    public let litFraction: Double
    /// The whole ring drawn at 35 percent opacity (a block or a discarded calibration).
    public let dimmed: Bool
    /// A checkmark replaces the camera; a full ring shows the large checked ring.
    public let checkmark: Bool
    /// Static tilt of the camera glyph in degrees, a cue for the pose being asked for.
    public let tiltDegrees: Double

    public init(
        litFraction: Double, dimmed: Bool = false, checkmark: Bool = false, tiltDegrees: Double = 0
    ) {
        self.litFraction = min(1, max(0, litFraction))
        self.dimmed = dimmed
        self.checkmark = checkmark
        self.tiltDegrees = tiltDegrees
    }

    /// The ticks lit at the start of a pose search, so "looking" reads as a started ring.
    public static let lookingFraction = 0.15

    public static func make(_ phase: GyroRingPhase) -> GyroRingModel {
        switch phase {
        case .intro:
            return GyroRingModel(litFraction: 0)
        case .posing(let step, let inZone, let hold):
            let lit = inZone ? lookingFraction + (1 - lookingFraction) * min(1, max(0, hold)) : lookingFraction
            return GyroRingModel(litFraction: lit, tiltDegrees: tilt(step))
        case .blocked(let step, _):
            return GyroRingModel(litFraction: lookingFraction, dimmed: true, tiltDegrees: tilt(step))
        case .retrying:
            return GyroRingModel(litFraction: 0)
        case .invalidated:
            return GyroRingModel(litFraction: 0, dimmed: true)
        case .complete:
            return GyroRingModel(litFraction: 1, checkmark: true)
        }
    }

    private static func tilt(_ step: GyroRingStep) -> Double {
        switch step {
        case .level: return 0
        case .tiltUp: return -14
        case .tiltAndLean: return -24
        }
    }

    /// Number of lit ticks out of 60.
    public var litTicks: Int { Int((litFraction * 60).rounded(.up)) }
}

/// Which spoken hold-progress milestone (25, 50 or 75 percent) a hold crossing reached.
public enum GyroHoldMilestones {
    public static let percents = [25, 50, 75]

    /// The highest milestone at or below `hold`, 0 when below the first.
    public static func bucket(_ hold: Double) -> Int {
        percents.last { hold >= Double($0) / 100 } ?? 0
    }

    /// The percent to announce when the hold moved from `previousBucket` to `hold`, nil when it
    /// crossed nothing new (a falling hold announces nothing and rearms the milestones).
    public static func crossing(previousBucket: Int, hold: Double) -> Int? {
        let now = bucket(hold)
        return now > previousBucket ? now : nil
    }
}

#if os(iOS)
    import MonitorUI
    import SwiftUI

    /// 60 dotted ticks around the camera glyph. Sized from the space it is given.
    public struct GyroRing: View {
        private let model: GyroRingModel

        public init(model: GyroRingModel) { self.model = model }

        public var body: some View {
            GeometryReader { proxy in
                let d = min(min(proxy.size.width, proxy.size.height) * 0.7, 260)
                ZStack {
                    if model.checkmark && model.litFraction >= 1 {
                        GyroCheckGlyph(size: d)
                    } else {
                        ticks(diameter: d)
                        if model.checkmark {
                            GyroCheckMark()
                                .stroke(
                                    MonitorTheme.accent,
                                    style: StrokeStyle(
                                        lineWidth: d * 0.06, lineCap: .round, lineJoin: .round)
                                )
                                .frame(width: d * 0.5, height: d * 0.5)
                        } else {
                            GyroCameraGlyph(width: d * 0.44)
                                .rotationEffect(.degrees(model.tiltDegrees))
                        }
                    }
                }
                .opacity(model.dimmed ? 0.35 : 1)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }

        private func ticks(diameter d: CGFloat) -> some View {
            let lit = model.litTicks
            let accent = MonitorTheme.accent
            let track = GyroPalette.track
            return Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let length = d * 0.10
                let outer = d / 2
                let inner = outer - length
                for index in 0..<60 {
                    let angle = -Double.pi / 2 + Double(index) * 2 * Double.pi / 60
                    var path = Path()
                    path.move(
                        to: CGPoint(
                            x: center.x + inner * CGFloat(cos(angle)),
                            y: center.y + inner * CGFloat(sin(angle))))
                    path.addLine(
                        to: CGPoint(
                            x: center.x + outer * CGFloat(cos(angle)),
                            y: center.y + outer * CGFloat(sin(angle))))
                    context.stroke(
                        path, with: .color(index < lit ? accent : track),
                        style: StrokeStyle(lineWidth: d * 0.026, lineCap: .round))
                }
            }
            .frame(width: d, height: d)
        }
    }
#endif
