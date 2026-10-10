#if os(iOS)
import OpenCineMedia
import SwiftUI

/// Geometry for the paper-black to source-ceiling IRE axis.
public enum MonitorWaveformAxis {
    /// 1pt so the 0 / 100 strokes sit inside the rounded clip.
    public static let plotInset: CGFloat = 1
    public static let titleHeight: CGFloat = 26
    /// Tight floor - just enough that the 0 stroke is not clipped.
    public static let bottomPad: CGFloat = 2
    public static let sidePad: CGFloat = 6
    /// Dotted safe-border guides, 5 IRE in from 0 and 100.
    public static let bufferIRE = 5.0
    /// Finger jitter that still counts as "hold for options", not a drag.
    public static let optionsDragSlop: CGFloat = 8
    public static let crushClipDash: [CGFloat] = [3, 3]

    public static func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: sidePad,
            y: titleHeight,
            width: size.width - sidePad * 2,
            height: max(1, size.height - titleHeight - bottomPad))
    }

    /// 0 = paper black, 1 = live-tap clip. Never goes through
    /// ``ScopeDisplayScale.crushLevel`` (that 0.05 is the leftover 5% shelf).
    /// `clipByte` is the source's live-tap ceiling for `transfer` (the bundle's, on screen).
    public static func unit(
        _ encoded: Double, transfer: MonitorTransfer, clipByte: Int
    ) -> Double {
        ire(encoded, transfer: transfer, clipByte: clipByte) / 100.0
    }

    /// IRE 0…100. Paper black is 0, clip is 100, 18% gray is paper IRE.
    public static func ire(_ encoded: Double, transfer: MonitorTransfer, clipByte: Int) -> Double {
        OpenCineMedia.WaveformIre.ire(encoded, transfer: transfer, clipByte: clipByte)
    }

    /// `ire` is 0…100 (not a 0…1 unit). Passing `crushLevel` 0.05 lands on
    /// the 0 line, not 5% up the plot.
    public static func plotY(_ ire: Double, _ rect: CGRect) -> CGFloat {
        let inset = plotInset
        let span = rect.height - 2 * inset
        return rect.maxY - inset - CGFloat(ire / 100.0) * span
    }

    /// Left-to-right twin of ``plotY`` - IRE 0 / 100 sit on the plot edges.
    public static func plotX(_ ire: Double, _ rect: CGRect) -> CGFloat {
        let inset = plotInset
        let span = rect.width - 2 * inset
        return rect.minX + inset + CGFloat(ire / 100.0) * span
    }

    /// Native-code histogram counts onto the WAVE IRE axis. Paper black is
    /// bucket 0, live-tap clip is bucket 255. Conserves total count.
    public static func remapHistogram(_ bins: [Int], transfer: MonitorTransfer, clipByte: Int) -> [Int] {
        OpenCineMedia.WaveformIre.remapHistogram(bins, transfer: transfer, clipByte: clipByte)
    }

    public static func scaleLineY(_ scaleIRE: Double, _ rect: CGRect) -> CGFloat {
        plotY(scaleIRE, rect)
    }

    public static func traceY(
        _ byte: UInt8, transfer: MonitorTransfer, clipByte: Int, _ rect: CGRect
    ) -> CGFloat {
        plotY(ire(Double(byte) / 255.0, transfer: transfer, clipByte: clipByte), rect)
    }

    public static func middleGrayIRE(transfer: MonitorTransfer) -> Double {
        transfer.middleGrayPaperIRE
    }

    /// Metal `trace_v` centres a point at `position + size/2`. Offset so the
    /// visual centre lands on the guide, not a half-pixel above it.
    public static func vertexPositionY(ire: Double, pointSize: Float, rect: CGRect) -> Float {
        Float(plotY(ire, rect)) - pointSize * 0.5
    }

    /// Visual centre after the Metal `position + size/2` offset.
    public static func visualCenterY(ire: Double, pointSize: Float, rect: CGRect) -> Float {
        vertexPositionY(ire: ire, pointSize: pointSize, rect: rect) + pointSize * 0.5
    }

    /// Paper / legal-black code this transfer's tap emits (`encode(0)`). Black does not
    /// depend on the ceiling.
    public static func legalBlackByte(transfer: MonitorTransfer) -> UInt8 {
        UInt8((ScopeAnchors.make(transfer: transfer, clipByte: 255).black * 255).rounded())
    }

    /// 256 IRE values (0…100). Paper black is 0, not 0.05.
    public static func levelTable(for transfer: MonitorTransfer, clipByte: Int) -> [Float] {
        OpenCineMedia.WaveformIre.levelTable(for: transfer, clipByte: clipByte)
    }

    public struct GuideStroke: Equatable, Sendable {
        public var ire: Double
        public var dashed: Bool
        public var usesCrushClipColor: Bool
        public init(ire: Double, dashed: Bool, usesCrushClipColor: Bool) {
            self.ire = ire; self.dashed = dashed; self.usesCrushClipColor = usesCrushClipColor
        }
    }

    /// Solid 0 / 100 on the plot edges. Optional dotted 5 / 95 safe borders.
    /// Middle gray is the log paper IRE, not 50.
    public static func guideStrokes(
        clip: Bool, crush: Bool, middle: Bool, transfer: MonitorTransfer
    ) -> [GuideStroke] {
        guideStrokes(
            clip: clip, crush: crush, middle: middle,
            middleGrayIRE: middleGrayIRE(transfer: transfer))
    }

    public static func guideStrokes(
        clip: Bool, crush: Bool, middle: Bool, middleGrayIRE grayIRE: Double
    ) -> [GuideStroke] {
        var strokes = [
            GuideStroke(ire: 0, dashed: false, usesCrushClipColor: false),
            GuideStroke(ire: 100, dashed: false, usesCrushClipColor: false),
        ]
        if crush {
            strokes.append(
                GuideStroke(ire: bufferIRE, dashed: true, usesCrushClipColor: true))
        }
        if clip {
            strokes.append(
                GuideStroke(ire: 100 - bufferIRE, dashed: true, usesCrushClipColor: true))
        }
        if middle {
            strokes.append(GuideStroke(ire: grayIRE, dashed: false, usesCrushClipColor: false))
        }
        return strokes
    }

    public static func shouldPresentOptions(translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) <= optionsDragSlop
    }
}
#endif
