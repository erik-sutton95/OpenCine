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
        var out = [Int](repeating: 0, count: 256)
        let table = levelTable(for: transfer, clipByte: clipByte)
        for code in 0..<min(bins.count, 256) where bins[code] != 0 {
            let bucket = Int((Double(table[code]) / 100.0 * 255).rounded())
            out[min(255, max(0, bucket))] += bins[code]
        }
        return out
    }

    public static func levelTable(for transfer: MonitorTransfer, clipByte: Int) -> [Float] {
        (0...255).map { Float(ire(Double($0) / 255.0, transfer: transfer, clipByte: clipByte)) }
    }
}
