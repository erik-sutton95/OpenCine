#if os(iOS)
import MonitorPresentation
import OpenCineMedia
import SwiftUI

public typealias MonitorWaveformMode = MonitorPresentation.MonitorWaveformMode
public typealias MonitorParadeMode = MonitorPresentation.MonitorParadeMode
public typealias MonitorVectorscopeZoom = MonitorPresentation.MonitorVectorscopeZoom
public typealias MonitorScopeGuides = MonitorPresentation.MonitorScopeGuides

public enum MonitorScopeGeometry {
    /// Legacy meter axis retained for existing plot geometry goldens.
    public static func legacyLevelY(_ level: Double, _ rect: CGRect) -> CGFloat {
        let fraction = (level - ScopeDisplayScale.crushLevel) / (ScopeDisplayScale.clipLevel - ScopeDisplayScale.crushLevel)
        return rect.maxY - CGFloat(0.04 + fraction * 0.92) * rect.height
    }
    public static func legacyScaleLineY(_ ire: Double, _ rect: CGRect) -> CGFloat {
        legacyLevelY(ScopeDisplayScale.level(scaleIRE: ire), rect)
    }
    public static func legacyTraceLevelY(_ byte: UInt8, transfer: MonitorTransfer = .rec709, clipByte: Int, _ rect: CGRect) -> CGFloat {
        legacyLevelY(Double(ScopeDisplayScale.levelTable(for: transfer, clipByte: clipByte)[Int(byte)]), rect)
    }
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
#endif
