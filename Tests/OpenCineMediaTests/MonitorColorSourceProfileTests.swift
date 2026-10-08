import OpenCineMedia
import Testing

@Suite struct MonitorColorSourceProfileTests {
    private let profile = MonitorColorSourceProfile(transferInference: [
        .init(fallback: .rec709, transfer: .dlog2, minByte: 12...22, maxByte: 180...252),
        .init(fallback: .rec709, transfer: .dlog, minByte: 20...30, maxByte: 160...240),
    ])

    @Test func absentSignatureNeverInfersADeclaredSource() {
        #expect(MonitorColorSourceProfile().inferredTransfer(minByte: 16, maxByte: 247, fallback: .rec709) == .rec709)
        #expect(MonitorColorSourceProfile().inferredTransfer(minByte: 24, maxByte: 223, fallback: .ilog) == .ilog)
    }
    @Test func declaredTransferWinsOverPreviewSignature() {
        for fallback in MonitorTransfer.allCases where fallback != .rec709 {
            #expect(profile.inferredTransfer(minByte: 16, maxByte: 247, fallback: fallback) == fallback)
        }
    }
    @Test func orderedSignaturesPreserveOverlapAndInclusiveBounds() {
        #expect(profile.inferredTransfer(minByte: 20, maxByte: 220, fallback: .rec709) == .dlog2)
        #expect(profile.inferredTransfer(minByte: 12, maxByte: 180, fallback: .rec709) == .dlog2)
        #expect(profile.inferredTransfer(minByte: 22, maxByte: 252, fallback: .rec709) == .dlog2)
        #expect(profile.inferredTransfer(minByte: 30, maxByte: 160, fallback: .rec709) == .dlog)
        #expect(profile.inferredTransfer(minByte: 11, maxByte: 247, fallback: .rec709) == .rec709)
        #expect(profile.inferredTransfer(minByte: 16, maxByte: 253, fallback: .rec709) == .rec709)
    }
}
