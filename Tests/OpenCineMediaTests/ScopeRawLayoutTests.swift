import OpenCineMedia
import Testing

struct ScopeRawLayoutTests {
    @Test func explicitLayoutsPreserveEncodedChannelsAndExactLuma() {
        let rgba: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255]
        let bgra: [UInt8] = [0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255]
        let first = ScopeSampler.sampleRaw(bytes: rgba, width: 3, height: 1, bytesPerRow: 12,
            transfer: .rec709, includePoints: true, layout: .rgba, stride: 1)
        let second = ScopeSampler.sampleRaw(bytes: bgra, width: 3, height: 1, bytesPerRow: 12,
            transfer: .rec709, includePoints: true, layout: .bgra, stride: 1)
        #expect(first == second)
        #expect(first.points.map(\.luma) == [54, 182, 18])
        #expect(first.points.map(\.red) == [255, 0, 0])
        #expect(first.points.allSatisfy { $0.sampleX == nil && $0.sampleY == nil })
    }
    @Test func paddedRowsAndRequestedStridePreserveExactKnownCoordinates() {
        var bytes = [UInt8](repeating: 0, count: 48)
        for y in 0..<3 { for x in 0..<3 { bytes[y * 16 + x * 4] = UInt8(y * 10 + x) } }
        let samples = ScopeSampler.sampleRaw(bytes: bytes, width: 3, height: 3, bytesPerRow: 16,
            transfer: .rec709, includePoints: true, layout: .rgba, stride: 2,
            includeSampleCoordinates: true, requireCompleteRows: true)
        #expect(samples.points.map(\.red) == [0, 2, 20, 22])
        #expect(samples.points.map(\.sampleX) == [0, 2, 0, 2])
        #expect(samples.points.map(\.sampleY) == [0, 0, 2, 2])
        #expect(samples.histogramRed.reduce(0, +) == 4)
    }
    @Test func incompleteRowsRefuseOnlyUnderExplicitSourcePolicy() {
        let bytes: [UInt8] = [255, 0, 0, 255, 255, 255]
        let compatibility = ScopeSampler.sampleRaw(bytes: bytes, width: 2, height: 2, bytesPerRow: 8,
            transfer: .rec709, includePoints: true)
        let refused = ScopeSampler.sampleRaw(bytes: bytes, width: 2, height: 2, bytesPerRow: 8,
            transfer: .rec709, includePoints: true, requireCompleteRows: true)
        #expect(compatibility.points.count == 1)
        #expect(refused == .empty)
    }
    @Test func originalAppleDefaultRetainsBGRAAndNoInventedCoordinates() {
        let samples = ScopeSampler.sampleRaw(bytes: [10, 20, 30, 255], width: 1, height: 1,
            bytesPerRow: 4, transfer: .rec709, includePoints: true)
        #expect(samples.points.first?.red == 30)
        #expect(samples.points.first?.blue == 10)
        #expect(samples.points.first?.sampleX == nil)
        #expect(samples.points.first?.sampleY == nil)
    }
}
