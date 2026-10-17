import OpenCineMedia
import Testing

struct MonitorPlaybackBufferValuesTests {
    @Test func nativeTemporalExtentIsIndependentOfDownloadedBytesAndLegacyUnits() {
        let values = MonitorPlaybackSourceValues(
            progress: 0.9, buffered: 0.8,
            bufferedThroughSeconds: 2.5)
        #expect(values.bufferedTemporalFraction(nativeDuration: 100) == 0.025)
        #expect(values.progress == 0.9)
        #expect(values.buffered == 0.8)
        #expect(values.bufferedThroughSeconds == 2.5)
    }

    @Test func unknownAndInvalidTemporalFactsNeverInventBufferCoverage() {
        for through in [nil, -1, Double.nan, Double.infinity] as [Double?] {
            let values = MonitorPlaybackSourceValues(
                progress: 1, buffered: 1,
                bufferedThroughSeconds: through)
            #expect(values.bufferedTemporalFraction(nativeDuration: 100) == nil)
        }
        let values = MonitorPlaybackSourceValues(bufferedThroughSeconds: 2.5)
        for duration in [nil, 0, -1, Double.nan, Double.infinity] as [Double?] {
            #expect(values.bufferedTemporalFraction(nativeDuration: duration) == nil)
        }
        #expect(
            MonitorPlaybackSourceValues(bufferedThroughSeconds: 0)
                .bufferedTemporalFraction(nativeDuration: 100) == 0)
        #expect(
            MonitorPlaybackSourceValues(bufferedThroughSeconds: 200)
                .bufferedTemporalFraction(nativeDuration: 100) == 1)
    }

    @Test func originalNamedConstructorKeepsLegacySourceFacts() {
        let values = MonitorPlaybackSourceValues(
            availability: .camera, progress: 0.5,
            buffered: 0.25, colorLabel: "SIMULATED", transfer: nil, clipByte: nil,
            metadata: [], clockStyle: .elapsed)
        #expect(values.buffered == 0.25)
        #expect(values.bufferedThroughSeconds == nil)
        #expect(values.bufferedTemporalFraction(nativeDuration: 100) == nil)
    }
}
