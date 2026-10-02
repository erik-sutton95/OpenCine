import Foundation
import Testing

@testable import OpenCineMedia

/// Golden anchors for ``MonitorTransfer/ilog`` from the Insta360 10-bit I-Log white paper
/// (June 2026, printed p3 equations, p3 table). See docs/research/luna-i-log-white-paper.md
/// in OpenInstaCine for the source hash and the derived values below.
@Suite struct ILogWhitePaperTests {
    private func encode(_ linear: Double) -> Double {
        LiveColorScience.encode(linear, transfer: .ilog)
    }

    @Test func publishedTableAnchors() {
        // Paper table: black 0.0905593 / 93, 18% grey 0.422003 / 432, 2200% 1.0 / 1023.
        #expect(abs(encode(0) - 0.0905593) < 5e-8)
        #expect(Int((encode(0) * 1023).rounded()) == 93)
        #expect(abs(encode(0.18) - 0.422003) < 5e-7)
        #expect(Int((encode(0.18) * 1023).rounded()) == 432)
        #expect(abs(encode(22) - 1.0) < 1e-6)
        #expect(Int((encode(22) * 1023).rounded()) == 1023)
    }

    @Test func derivedPrecisionAnchors() {
        // Evaluated from the published coefficients (research note table).
        #expect(abs(encode(0) - 0.0905593400) < 1e-10)
        #expect(abs(encode(0.18) - 0.4220033397) < 1e-10)
        #expect(abs(encode(1) - 0.6252022223) < 1e-10)
        #expect(abs(encode(22) - 0.9999994560) < 1e-10)
        #expect(abs(MonitorTransfer.ilog.peakLinear - 22.00009844) < 1e-6)
        #expect(abs(MonitorTransfer.ilog.middleGrayEncoded - 0.4220033397) < 1e-10)
    }

    @Test func branchesMeetAtThePublishedBreakpoints() {
        // Linear branch at 0.01104854 vs the log expression: about 2.46e-9 apart.
        let linear = 5.77837328 * 0.01104854 + 0.09055934
        let log = 0.623992 + 0.280055 * log10(0.01104854 + 0.01)
        #expect(abs(linear - log) < 3e-9)
        #expect(abs(encode(0.01104854) - linear) < 1e-15)
        // Decode inverts encode across both branches.
        for x in [0.0, 0.005, 0.01104854, 0.02, 0.18, 1, 10, 22] {
            let back = LiveColorScience.linearize(encode(x), transfer: .ilog)
            #expect(abs(back - x) <= max(1e-8, x * 1e-8), "round trip at \(x)")
        }
    }

    @Test func usesBT2020LumaWeights() {
        let w = LiveColorScience.lumaWeights(.ilog)
        #expect(w.red == 0.2627 && w.green == 0.6780 && w.blue == 0.0593)
    }
}
