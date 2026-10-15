import Foundation
import OpenCineMedia
import Testing

@Suite struct LegacyScopePolicyTests {
    private let calibration = LegacyScopeCalibration(blackNative: 20, middleGrayNative: 80,
        clipNative: 200, defaultClipNative: 200, crushUpperNative: 24)
    private func histogram(_ entries: [(Int, Int)]) -> [Int] {
        var result = [Int](repeating: 0, count: 256)
        for (bin, count) in entries { result[bin] = count }
        return result
    }
    private func point(_ code: UInt8) -> ScopePoint {
        ScopePoint(xRatio: 0, yRatio: 0, red: code, green: code, blue: code, luma: code)
    }

    @Test func fixedAnchorsUseDefaultClipForGray() {
        let shifted = LegacyScopeCalibration(blackNative: 20, middleGrayNative: 80,
            clipNative: 180, defaultClipNative: 200, crushUpperNative: 24)
        #expect(abs(LegacyScopePolicy.middleGrayLevel(calibration: calibration) - 0.35) < 1e-12)
        #expect(LegacyScopePolicy.middleGrayLevel(calibration: shifted) == LegacyScopePolicy.middleGrayLevel(calibration: calibration))
        #expect(LegacyScopePolicy.waveformLevel(signalNative: 20, calibration: shifted) == 0.05)
        #expect(LegacyScopePolicy.waveformLevel(signalNative: 180, calibration: shifted) == 0.95)
        #expect(LegacyScopePolicy.waveformLevel(signalNative: 255, calibration: shifted) == 1)
    }
    @Test func histogramMedianKeepsLowerEvenBin() {
        #expect(LegacyScopePolicy.medianWaveformLevel(histogram: histogram([(20, 1), (200, 1)]), calibration: calibration) == 0.05)
    }
    @Test func pointMedianAveragesEvenLevels() {
        #expect(LegacyScopePolicy.medianWaveformLevel(points: [point(200), point(20)], calibration: calibration, channel: { $0.red }) == 0.5)
    }
    @Test func histogramTotalsUseWideCounters() {
        let bins = histogram([(20, 1_000_000_000), (80, 1_000_000_000), (255, 1_000_000_000)])
        #expect(abs(LegacyScopePolicy.medianWaveformLevel(histogram: bins, calibration: calibration) - 0.35) < 1e-12)
        #expect(LegacyScopePolicy.trafficLights(red: bins, green: bins, blue: bins, calibration: calibration).clipRed)
    }
    @Test func edgeEnergyIsStrictAndExcludesSubFloor() {
        let exactly = histogram([(80, 90), (255, 10)])
        #expect(!LegacyScopePolicy.trafficLights(red: exactly, green: exactly, blue: exactly, calibration: calibration, threshold: 0.10).clipRed)
        let belowToe = histogram([(0, 100)])
        #expect(!LegacyScopePolicy.trafficLights(red: belowToe, green: belowToe, blue: belowToe, calibration: calibration).crushRed)
        let toe = histogram([(20, 100)])
        #expect(LegacyScopePolicy.trafficLights(red: toe, green: toe, blue: toe, calibration: calibration).crushRed)
    }
    @Test func emptyHistogramInputKeepsOriginalZeros() {
        #expect(LegacyScopePolicy.medianWaveformLevel(histogram: [1, 2, 3], calibration: calibration) == 0)
        #expect(LegacyTrafficLightsMeter.measure(samples: .empty, noiseFloorCompensation: .quarter, calibration: calibration) == .empty)
    }
    @Test func individualChannelsClipIndependently() {
        let gray = histogram([(80, 100)])
        let reading = LegacyTrafficLightsMeter.measure(samples: ScopeSamples(histogramLuma: gray,
            histogramRed: histogram([(255, 100)]), histogramGreen: gray, histogramBlue: gray, points: []),
            noiseFloorCompensation: .quarter, calibration: calibration)
        #expect(reading.red.clip && !reading.green.clip && !reading.blue.clip)
        #expect(reading.red.level == 1 && reading.green.level == 0.5)
    }
    @Test func channelLevelUsesHistogramBeforePoints() {
        let gray = histogram([(80, 100)])
        let samples = ScopeSamples(histogramLuma: gray, histogramRed: gray, histogramGreen: gray,
            histogramBlue: gray, points: [point(255)])
        #expect(LegacyTrafficLightsMeter.channelLevel(samples: samples, channel: .red, calibration: calibration) == 0.5)
    }
    @Test func channelDisplayKeepsInclusiveDeadZone() {
        #expect(LegacyTrafficLightsMeter.channelDisplay(for: LegacyTrafficLightsChannelReading(level: 0.625, clip: false, crush: false), deadZone: 0.125) == .neutral)
        let over = LegacyTrafficLightsMeter.channelDisplay(for: LegacyTrafficLightsChannelReading(level: 0.75, clip: false, crush: false))
        let under = LegacyTrafficLightsMeter.channelDisplay(for: LegacyTrafficLightsChannelReading(level: 0.25, clip: false, crush: false))
        #expect(over.side == .over && over.barFill == 0.5)
        #expect(under.side == .under && under.barFill == 0.5)
    }
}
