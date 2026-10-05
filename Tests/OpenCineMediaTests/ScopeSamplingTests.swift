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

    @Test func sourceOwnedLevelAxisPlacesCodesAndGreyLine() {
        let transfer = ScopeLevelAxis(transfer: .dlog2, clipByte: 247)
        #expect(transfer.table == WaveformIre.levelTable(for: .dlog2, clipByte: 247))
        #expect(transfer.middleGrayIRE == MonitorTransfer.dlog2.middleGrayPaperIRE)

        // A source with its own placement: code c sits at c/255 * 100 IRE, grey at 41.
        let linear = ScopeLevelAxis(table: (0...255).map { Float($0) / 255 * 100 }, middleGrayIRE: 41)
        var bins = [Int](repeating: 0, count: 256)
        bins[0] = 5; bins[128] = 7; bins[255] = 9
        #expect(linear.remapHistogram(bins) == bins)
        let display = ScopeSampler.histogramDisplay(
            samples: ScopeSamples(histogramLuma: bins, histogramRed: bins, histogramGreen: bins,
                histogramBlue: bins, points: []),
            previous: .empty, axis: linear)
        #expect(display.luma == ScopeSampler.displayChannel(
            bins, previous: ScopeHistogramDisplay.empty.luma, axis: linear))
        #expect(display.luma[128] > 0)
    }

    @Test func vectorscopeRasterPremultipliesAndPutsPositiveCrUp() throws {
        #expect(VectorscopeRaster.pixels(from: [], gain: 1, intensity: 1) == nil)
        let red = ScopePoint(xRatio: 0, yRatio: 0, red: 255, green: 0, blue: 0, luma: 54)
        let blue = ScopePoint(xRatio: 0, yRatio: 0, red: 0, green: 0, blue: 255, luma: 18)
        let pixels = try #require(VectorscopeRaster.pixels(from: [red, blue], gain: 1, intensity: 1))
        let n = VectorscopeRaster.bins
        func row(of point: ScopePoint) -> Int {
            // Storage row 0 is the most negative Cr; the raster flips it so +Cr is drawn up.
            n - 1 - VectorscopeRaster.binIndex(red: point.red, green: point.green, blue: point.blue)!.row
        }
        func pixel(_ point: ScopePoint) -> ArraySlice<UInt8> {
            let column = VectorscopeRaster.binIndex(red: point.red, green: point.green, blue: point.blue)!.column
            let index = (row(of: point) * n + column) * 4
            return pixels[index..<(index + 4)]
        }
        #expect(row(of: red) < row(of: blue))
        // Premultiplied: no colour channel exceeds alpha, and each landed bin is lit.
        for point in [red, blue] {
            let rgba = Array(pixel(point))
            #expect(rgba[3] > 0)
            #expect(rgba[0] <= rgba[3] && rgba[1] <= rgba[3] && rgba[2] <= rgba[3])
        }
        #expect(pixel(red)[pixel(red).startIndex] > pixel(red)[pixel(red).startIndex + 2])
    }

    @Test func samplingCadenceShedsScopes() {
        #expect(ScopeSampler.sampleInterval(activeScopeCount: 2) == 1.0 / 25)
        #expect(ScopeSampler.sampleInterval(activeScopeCount: 3) == 1.0 / 10)
        #expect(abs(ScopeSampler.sampleInterval(activeScopeCount: 3, thermalMultiplier: 3) - 0.3) < 1e-12)
    }
}
