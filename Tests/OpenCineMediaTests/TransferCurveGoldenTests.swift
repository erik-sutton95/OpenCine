import Foundation
import Testing

@testable import OpenCineMedia

/// The Nikon curves at the values OpenZCineCore's ExposureScaleTests publish (N-Log 1.0.0,
/// RED 915-0187 Rev C, IEC 61966-2-1). Same goldens as Kotlin `TransferCurveGoldenTest`.
@Suite struct TransferCurveGoldenTests {
    @Test func log3G10MatchesTheRedMappingTable() {
        for (linear, encoded) in [
            (-0.01, 0.0), (0.0, 0.091551), (0.18, 0.333333), (1.0, 0.493449), (184.322, 1.0),
        ] {
            #expect(abs(Log3G10.encode(linear) - encoded) <= 0.000005, "Log3G10 at \(linear)")
        }
        #expect(abs(LiveColorScience.encode(0, transfer: .log3G10) - 0.091551) <= 0.000001)
        #expect(abs(MonitorTransfer.log3G10.middleGrayEncoded - 1.0 / 3.0) <= 0.000001)
        #expect(abs(LiveColorScience.linearize(1.0 / 3.0, transfer: .log3G10) - 0.18) <= 0.00001)
        #expect(abs(MonitorTransfer.log3G10.peakLinear - 184.322348) <= 0.000001)
    }

    @Test func nLogMatchesTheSpecification() {
        let middleGray = MonitorTransfer.nlog.middleGrayEncoded
        #expect(abs(middleGray * 1023 - 372.032) <= 0.01)
        #expect(abs(LiveColorScience.linearize(middleGray, transfer: .nlog) - 0.18) <= 0.00001)
        #expect(abs(LiveColorScience.encode(0, transfer: .nlog) * 1023 - 127.2) <= 0.1)
        // The segments meet at reflectance 0.328 (10-bit code 452).
        #expect(abs(650 * pow(0.328 + 0.0075, 1.0 / 3.0) - (150 * log(0.328) + 619)) <= 0.15)
        #expect(abs(NLog.decode(451.9 / 1023) - NLog.decode(452.1 / 1023)) <= 0.001)
        #expect(abs(MonitorTransfer.nlog.peakLinear - 14.780863) <= 0.000001)
    }

    @Test func srgbHitsTheIecReferencePoints() {
        #expect(abs(MonitorTransfer.srgb.middleGrayEncoded - 0.46136) <= 0.0005)
        #expect(LiveColorScience.encode(0, transfer: .srgb) == 0)
        #expect(abs(LiveColorScience.encode(1, transfer: .srgb) - 1) <= 0.0001)
        // Display-referred: no headroom above display white.
        #expect(abs(LiveColorScience.encode(2, transfer: .srgb) - 1) <= 0.0001)
        let half = LiveColorScience.encode(0.5, transfer: .srgb)
        #expect(abs(LiveColorScience.linearize(half, transfer: .srgb) - 0.5) <= 0.0001)
        #expect(MonitorTransfer.srgb.peakLinear == 1)
    }

    @Test func everyNewCurveRoundTripsAcrossItsRange() {
        for transfer in [MonitorTransfer.srgb, .nlog, .log3G10] {
            // Codes below black decode to negative light, which linearize floors at zero.
            let black = LiveColorScience.encode(0, transfer: transfer)
            for step in 1...99 {
                let encoded = Double(step) / 100
                if encoded <= black { continue }
                let back = LiveColorScience.encode(
                    LiveColorScience.linearize(encoded, transfer: transfer), transfer: transfer)
                #expect(abs(back - encoded) <= 0.000001, "\(transfer) at \(encoded)")
            }
            #expect(transfer.middleGrayEncoded > black)
        }
    }

    @Test func newCurvesKeepTheirNamesAndWeights() {
        #expect(
            MonitorTransfer.allCases.suffix(3).map(\.label) == ["sRGB", "N-Log", "Log3G10"])
        // Appended after the existing cases, whose order and raw values are saved data.
        #expect(
            MonitorTransfer.allCases.map(\.rawValue) == [
                "rec709", "hdr", "dlog", "dlog2", "dlogm", "ilog", "srgb", "nlog", "log3G10",
            ])
        #expect(LiveColorScience.lumaWeights(.srgb) == (0.2126, 0.7152, 0.0722))
        #expect(LiveColorScience.lumaWeights(.nlog) == (0.2627, 0.6780, 0.0593))
        #expect(LiveColorScience.lumaWeights(.log3G10) == (0.286694, 0.842979, -0.129673))
    }
}
