#if canImport(CoreImage)
import OpenCineApple
import OpenCineMedia
import Testing

@Suite struct MonitorPeakingSourceCalibrationTests {
    @Test func portableAndEnginePlansUseTheSourcesTransfer() {
        for transfer in MonitorTransfer.allCases {
            let expected = [MonitorTransfer.rec709, .hdr, .srgb].contains(transfer) ? 1.57 * 1.57 : 1
            var portable = MonitorFrameEffects()
            portable.transfer = transfer
            #expect(portable.nativeImagePlan.peakingGateScale == expected)
            var policy = MonitorAssistPolicy()
            policy.stamp(transfer: transfer, ceiling: ScopeExposureCeiling())
            #expect(policy.image.peakingGateScale == expected)
        }
    }
}
#endif
