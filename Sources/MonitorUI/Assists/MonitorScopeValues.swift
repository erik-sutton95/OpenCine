#if os(iOS)
import SwiftUI

public enum MonitorWaveformMode: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case luma = "Luma"
    case rgb = "RGB"
    public var id: String { rawValue }
}

public enum MonitorParadeMode: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case rgb = "RGB"
    case yrgb = "YRGB"
    public var id: String { rawValue }
    public var laneCount: Int { self == .yrgb ? 4 : 3 }
}

public enum MonitorVectorscopeZoom: String, CaseIterable, Codable, Equatable, Sendable, Identifiable {
    case x1 = "1x"
    case x2 = "2x"
    case x4 = "4x"
    public var id: String { rawValue }
    public var gain: Double {
        switch self { case .x1: 1; case .x2: 2; case .x4: 4 }
    }
}

public enum MonitorScopeGeometry {
    public static func laneX(xRatio: Double, lane: Int, mode: MonitorParadeMode, plot: CGRect) -> CGFloat {
        let width = plot.width / CGFloat(mode.laneCount)
        return plot.minX + CGFloat(lane) * width + CGFloat(xRatio) * (width - 1)
    }
    public static func plotRect(_ size: CGSize, top: CGFloat) -> CGRect {
        CGRect(x: 6, y: top, width: size.width - 12, height: size.height - top - 8)
    }
    public static func vectorscopeSquare(in size: CGSize) -> CGRect {
        let plot = plotRect(size, top: 26)
        let side = min(plot.width, plot.height)
        return CGRect(x: plot.midX - side / 2, y: plot.midY - side / 2, width: side, height: side)
    }
    public static func traceClipRect(_ plot: CGRect) -> CGRect { plot.insetBy(dx: 0, dy: -2) }
    public static func waveformIntensity(_ brightness: Int) -> Double { Double(min(max(brightness, 0), 200)) / 400 }
    public static func vectorscopeIntensity(_ brightness: Int) -> Double { Double(min(max(brightness, 0), 200)) / 100 }
}
public struct MonitorScopeGuides: Codable, Equatable, Sendable {
    public var clip: Bool
    public var crush: Bool
    public var middle: Bool
    public static let `default` = Self()
    public init(clip: Bool = true, crush: Bool = true, middle: Bool = true) {
        self.clip = clip; self.crush = crush; self.middle = middle
    }
}
#endif
