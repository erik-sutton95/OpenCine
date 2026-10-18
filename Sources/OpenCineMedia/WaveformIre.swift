import Foundation

/// Encoded source codes on the observed clip ceiling, with paper middle grey preserved.
public enum WaveformIre {
    public static func ire(
        _ encoded: Double, transfer: MonitorTransfer, clipByte: Int
    ) -> Double {
        let a = ScopeAnchors.make(transfer: transfer, clipByte: clipByte)
        // Byte-round paper black (D-Log2 15.95 → 16) must sit on 0, not 0.02 IRE.
        let blackByte = (a.black * 255).rounded()
        if !encoded.isFinite || encoded * 255 <= blackByte { return 0 }
        if encoded >= a.clip { return 100 }
        let midIRE = LiveColorScience.paperIRE(a.mid)
        if a.mid <= a.black || a.clip <= a.mid {
            return (encoded - a.black) / max(a.clip - a.black, 1e-9) * 100
        }
        if encoded <= a.mid {
            return (encoded - a.black) / (a.mid - a.black) * midIRE
        }
        return midIRE + (encoded - a.mid) / (a.clip - a.mid) * (100 - midIRE)
    }

    public static func remapHistogram(
        _ bins: [Int], transfer: MonitorTransfer, clipByte: Int
    ) -> [Int] {
        ScopeLevelAxis(transfer: transfer, clipByte: clipByte).remapHistogram(bins)
    }

    public static func levelTable(for transfer: MonitorTransfer, clipByte: Int) -> [Float] {
        (0...255).map { Float(ire(Double($0) / 255.0, transfer: transfer, clipByte: clipByte)) }
    }
}

/// Where each tap code lands on the 0...100 WAVE axis, and where the mid-grey guide sits.
/// A shared transfer builds it from its anchors; a source that owns a measured placement
/// supplies the table and grey line itself.
public struct ScopeLevelAxis: Equatable, Sendable {
    /// One axis value (0...100) per tap code: calibrated IRE or encoded-code percentage.
    public var table: [Float]
    public var middleGrayIRE: Double
    /// Whether this source supplied exposure calibration for grey, crush and clip references.
    public var supportsCalibratedReferences: Bool

    public init(table: [Float], middleGrayIRE: Double, supportsCalibratedReferences: Bool = true) {
        precondition(table.count == 256, "ScopeLevelAxis needs one axis value per tap code")
        self.table = table
        self.middleGrayIRE = middleGrayIRE
        self.supportsCalibratedReferences = supportsCalibratedReferences
    }

    /// Encoded-code percentage, retaining traces without assigning an unknown transfer or grey.
    /// `middleGrayIRE` is unused in this mode; no calibrated reference may consume it.
    public static let rawCodes = Self(
        table: (0...255).map { Float($0) / 255 * 100 }, middleGrayIRE: 0,
        supportsCalibratedReferences: false)

    public init(transfer: MonitorTransfer, clipByte: Int) {
        self.init(
            table: WaveformIre.levelTable(for: transfer, clipByte: clipByte),
            middleGrayIRE: transfer.middleGrayPaperIRE)
    }

    /// Native-code histogram counts onto this axis. Conserves total count.
    public func remapHistogram(_ bins: [Int]) -> [Int] {
        var out = [Int](repeating: 0, count: 256)
        for code in 0..<min(bins.count, 256) where bins[code] != 0 {
            let bucket = Int((Double(table[code]) / 100.0 * 255).rounded())
            out[min(255, max(0, bucket))] += bins[code]
        }
        return out
    }
}
