import Foundation
import Testing
@testable import OpenCineMedia

@Suite struct ScopeSamplingTests {
    @Test func singlePassKeepsNativeCodesAndSourceHistory() {
        let white = [UInt8](repeating: 255, count: 4 * 4 * 4)
        let first = ScopeSampler.sample(bytes: white, width: 4, height: 4, bytesPerRow: 16,
            transfer: .rec709, clipByte: 255, includePoints: true, look: nil, previous: .empty)
        #expect(first.samples.histogramLuma[255] == 4)
        #expect(first.samples.histogramRed[255] == 4)
        #expect(first.samples.points.count == 4)
        let dark = [UInt8](repeating: 16, count: 4 * 4 * 4)
        let second = ScopeSampler.sample(bytes: dark, width: 4, height: 4, bytesPerRow: 16,
            transfer: .dlog2, clipByte: 247, includePoints: true, look: nil, previous: first)
        #expect(second.revision == 2)
        #expect(second.samples.histogramLuma[16] == 4)
        #expect(second.trailSamples == first.samples)
        #expect(second.clipByte == 247)
        let independent = ScopeSampler.sample(bytes: dark, width: 4, height: 4, bytesPerRow: 16,
            transfer: .dlog2, clipByte: 200, includePoints: false, look: nil, previous: .empty)
        #expect(independent.revision == 1)
        #expect(independent.trailSamples == .empty)
        #expect(independent.clipByte == 200)
        #expect(first.clipByte == 255)
        #expect(second.clipByte == 247)
    }

    @Test func histogramRemapConservesCounts() {
        var bins = [Int](repeating: 0, count: 256)
        bins[16] = 10; bins[78] = 20; bins[247] = 30
        let remapped = WaveformIre.remapHistogram(bins, transfer: .dlog2, clipByte: 247)
        #expect(remapped[0] == 10)
        #expect(remapped[255] == 30)
        #expect(remapped.reduce(0, +) == 60)
    }

    @Test func samplingCadenceShedsScopes() {
        #expect(ScopeSampler.sampleInterval(activeScopeCount: 2) == 1.0 / 25)
        #expect(ScopeSampler.sampleInterval(activeScopeCount: 3) == 1.0 / 10)
        #expect(abs(ScopeSampler.sampleInterval(activeScopeCount: 3, thermalMultiplier: 3) - 0.3) < 1e-12)
    }
}
