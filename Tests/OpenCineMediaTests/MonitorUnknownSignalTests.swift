import Testing

@testable import OpenCineMedia

@Suite struct MonitorUnknownSignalTests {
    @Test func explicitUnknownNeverEvaluatesFallbackButLegacyDefaultsRemain() {
        var reads = 0
        func fallback() -> MonitorTransfer? {
            reads += 1
            return .dlog2
        }
        let unknown = MonitorPlaybackSourceValues(allowsSignalFallback: false)
        #expect(unknown.resolvedTransfer(fallback: fallback()) == nil)
        #expect(reads == 0)
        #expect(MonitorPlaybackSourceValues().resolvedTransfer(fallback: fallback()) == .dlog2)
        #expect(reads == 1)
        let known = MonitorPlaybackSourceValues(transfer: .dlogm, allowsSignalFallback: false)
        #expect(known.resolvedTransfer(fallback: fallback()) == .dlogm)
        #expect(reads == 1)
    }

    @Test func rawAxisRetainsEveryEncodedCodeWithoutCalibratedReferences() {
        let axis = ScopeLevelAxis.rawCodes
        #expect(!axis.supportsCalibratedReferences)
        #expect(axis.table.count == 256)
        for code in 0...255 {
            #expect(abs(Double(axis.table[code]) - Double(code) * 100 / 255) < 0.0001)
        }
        let counts = (0...255).map { $0 + 1 }
        #expect(axis.remapHistogram(counts) == counts)
        let legacy = ScopeLevelAxis(transfer: .dlog2, clipByte: 247)
        #expect(legacy.supportsCalibratedReferences)
        #expect(legacy == ScopeLevelAxis(table: legacy.table, middleGrayIRE: legacy.middleGrayIRE))
    }
}
