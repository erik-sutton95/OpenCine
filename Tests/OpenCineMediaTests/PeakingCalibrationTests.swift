import Testing

@testable import OpenCineMedia

struct PeakingCalibrationTests {
    @Test func persistedOptionsKeepTheirDetectorValues() {
        #expect(Peaking.Color.allCases.map(\.rawValue) == ["White", "Blue", "Red", "Green"])
        #expect(Peaking.Sensitivity.allCases.map(\.rawValue) == ["Low", "Med", "High"])
        #expect(Peaking.Sensitivity.allCases.map(\.ratioThreshold) == [2.30, 2.10, 1.90])
        #expect(Peaking.Sensitivity.allCases.map(\.noiseGate) == [0.00522, 0.00174, 0.00058])
    }

    @Test func everyTransferKeepsItsFormerFeedWireGate() {
        for transfer: MonitorTransfer in [.rec709, .hdr, .srgb] {
            #expect(Peaking.gateScale(for: transfer) == 1.57 * 1.57)
        }
        for transfer: MonitorTransfer in [.dlog, .dlog2, .dlogm, .ilog, .nlog, .log3G10] {
            #expect(Peaking.gateScale(for: transfer) == 1)
        }
    }
}
