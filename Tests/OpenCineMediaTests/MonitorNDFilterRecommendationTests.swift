import Foundation
import Testing

@testable import OpenCineMedia

@Suite struct MonitorNDFilterRecommendationTests {
    @Test func suggestionFollowsTheOpticalLadder() throws {
        for (stops, ndStops, label) in [(0.0, 0, "?"), (0.3, 0, "?"), (0.5, 1, "ND2"),
            (2.0, 2, "ND4"), (2.3, 2, "ND4"), (3.0, 3, "ND8"), (5.0, 5, "ND32"),
            (12.0, 10, "ND1000"), (-1.0, 0, "?"), (-1.5, 0, "?")] {
            let reading = try #require(MonitorNDFilterRecommendation.suggestion(pictureStops: stops))
            #expect(reading.ndStops == ndStops)
            #expect(reading.ndLabel == label)
            #expect(reading.needsGlass == (ndStops > 0))
        }
    }

    @Test func histogramMedianMapsToPictureStops() throws {
        var bins = [Int](repeating: 0, count: 256)
        bins[Int((MonitorTransfer.rec709.middleGrayEncoded * 255).rounded())] = 1_000
        let reading = try #require(MonitorNDFilterRecommendation.reading(lumaHistogram: bins, transfer: .rec709))
        #expect(abs(reading.pictureStops) < 0.15)
        #expect(reading.ndStops == 0)
    }

    @Test func unavailableMeasurementIsNotKnownZero() throws {
        for input in [Double.nan, .infinity, -.infinity] {
            #expect(MonitorNDFilterRecommendation.suggestion(pictureStops: input) == nil)
        }
        #expect(MonitorNDFilterRecommendation.reading(lumaHistogram: [], transfer: .rec709) == nil)
        #expect(MonitorNDFilterRecommendation.reading(lumaHistogram: [Int](repeating: 0, count: 256), transfer: .rec709) == nil)
        let zero = try #require(MonitorNDFilterRecommendation.suggestion(pictureStops: 0, noneLabel: "No ND"))
        #expect(zero.pictureStops == 0)
        #expect(zero.ndLabel == "No ND")
        #expect(!zero.needsGlass)
    }

    @Test func largestFiniteMeasurementCapsBeforeIntegerConversion() throws {
        let reading = try #require(MonitorNDFilterRecommendation.suggestion(pictureStops: .greatestFiniteMagnitude))
        #expect(reading.ndStops == 10)
        #expect(reading.opticalFactor == 1_000)
    }

    @Test func densityAndNotationPreserveMeasuredValues() throws {
        for (stops, label) in [(0.0, "ND 0.0"), (1.0, "ND 0.3"), (4.0 / 3.0, "ND 0.4"),
                              (5.0, "ND 1.5"), (-1.0, "ND −0.3")] {
            #expect(MonitorNDFilterRecommendation.densityLabel(stops) == label)
        }
        let hot = try #require(MonitorNDFilterRecommendation.suggestion(pictureStops: 5))
        #expect(hot.chipLabel(.stops) == "+5.0")
        #expect(hot.chipLabel(.factor) == "ND32")
        #expect(hot.chipLabel(.density) == "ND 1.5")
        #expect(MonitorNDFilterNotation.allCases.map(\.rawValue) == ["stops", "factor", "density"])
        #expect(MonitorNDFilterNotation.allCases.map(\.editorLabel) == ["Stops", "ND32", "ND 0.3"])
    }
}
