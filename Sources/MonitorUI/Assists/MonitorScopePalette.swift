#if os(iOS)
import SwiftUI

/// Additive trace colours shared by monitor scope plots.
public enum MonitorScopePalette {
    public struct TraceColor: Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double
        public let alpha: Double
        public init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        }
        public var color: Color {
            Color(red: red / 255, green: green / 255, blue: blue / 255, opacity: alpha)
        }
    }

    public static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }

    public static func trace(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> TraceColor {
        TraceColor(red: r, green: g, blue: b, alpha: a)
    }

    public static let lumaGhost = trace(182, 190, 186, 0.08)
    public static let luma = trace(222, 230, 224, 1.0)
    public static let lumaHot = trace(255, 255, 255, 1.0)
    /// RGB overlay waveform - mid alpha so coincident channels add toward white.
    public static let overlayRed = trace(255, 64, 54, 0.55)
    public static let overlayGreen = trace(70, 240, 110, 0.55)
    public static let overlayBlue = trace(72, 148, 255, 0.62)
    public static let paradeRed = trace(255, 86, 78, 1.0)
    public static let paradeGreen = trace(102, 232, 132, 1.0)
    public static let paradeBlue = trace(92, 156, 255, 1.0)
    public static let boundary = rgba(220, 235, 225, 0.8)
    public static let clip = rgba(255, 150, 142, 0.8)
    public static let middle = rgba(246, 241, 226, 0.8)
    /// Faint anchored-scale grid (25 / 50 / 75 lines).
    public static let grid = rgba(220, 235, 225, 0.10)
    public static let histogramRedFill = rgba(255, 48, 44, 0.17)
    public static let histogramGreenFill = rgba(0, 238, 70, 0.15)
    public static let histogramBlueFill = rgba(45, 76, 255, 0.19)
    public static let panelFill = Color(red: 0.025, green: 0.036, blue: 0.03).opacity(0.72)
}
#endif
