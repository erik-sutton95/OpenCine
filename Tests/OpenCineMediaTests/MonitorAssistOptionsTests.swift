import Foundation
import Testing
@testable import OpenCineMedia

@Suite struct MonitorAssistOptionsTests {
    @Test func detectorPaintsRetainGoldenRGBAndSensitivity() {
        let expected: [(Double, Double, Double)] = [
            (246.0 / 255, 241.0 / 255, 226.0 / 255),
            (64.0 / 255, 142.0 / 255, 1), (1, 72.0 / 255, 64.0 / 255),
            (74.0 / 255, 220.0 / 255, 132.0 / 255),
        ]
        for (color, rgb) in zip(MonitorPeakingColor.allCases, expected) {
            #expect(color.rgb.0 == rgb.0 && color.rgb.1 == rgb.1 && color.rgb.2 == rgb.2)
        }
        #expect(MonitorPeakingSense.allCases.map(\.ratioThreshold) == [2.30, 2.10, 1.90])
        #expect(MonitorPeakingSense.allCases.map(\.noiseGate) == [0.00522, 0.00174, 0.00058])
        #expect(MonitorPeakingOptions.default.overlay ==
            MonitorPeakingOverlaySpec(color: .red, sensitivity: .medium))
    }

    @Test func serializedOptionIdentitiesRemainCompatible() throws {
        let data = Data(#"{"color":"Blue","sensitivity":"High"}"#.utf8)
        let options = try JSONDecoder().decode(MonitorPeakingOptions.self, from: data)
        #expect(options.color == .blue && options.sensitivity == .high)
        #expect(try JSONDecoder().decode(MonitorPeakingOptions.self,
            from: JSONEncoder().encode(options)) == options)
        #expect(MonitorZebraPaint.allCases.map(\.rawValue) == ["White", "Amber", "Red", "Cyan", "Green"])
        let expected: [(Double, Double, Double)] = [(1, 1, 1), (1, 0.72, 0.2),
            (1, 0.15, 0.15), (0, 0.85, 0.9), (0.2, 0.9, 0.35)]
        for (paint, rgb) in zip(MonitorZebraPaint.allCases, expected) {
            #expect(paint.rgb.0 == rgb.0 && paint.rgb.1 == rgb.1 && paint.rgb.2 == rgb.2)
        }
    }

    @Test func histogramAndLightsRetainCompensationStopsAndLenientDecode() throws {
        #expect(MonitorCrushClipCompensation.allCases.map(\.rawValue) == [0, 2, 5, 7, 10])
        #expect(MonitorCrushClipCompensation.allCases.map(\.stops) == [0, 0.25, 0.5, 0.75, 1])
        #expect(MonitorCrushClipCompensation.allCases.map(\.compactLabel) == ["0", "¼", "½", "¾", "1"])
        for (raw, expected) in [(-1, 0), (3, 0), (15, 10), (2, 2), (5, 5)] {
            let value = try JSONDecoder().decode(MonitorCrushClipCompensation.self,
                from: Data(String(raw).utf8))
            #expect(value.rawValue == expected)
        }
        let half = MonitorCrushClipCompensation.half
        #expect(half.pixelFractionThreshold == 0.05)
        #expect(String(data: try JSONEncoder().encode(half), encoding: .utf8) == "5")
    }

    @Test func desqueezePresetsAndHundredthsRetainTheirIdentities() {
        #expect(MonitorDesqueezePreset.allCases.map(\.factor) == [1.1, 1.2, 1.33, 1.5, 1.6, 1.8, 2])
        for hundredths in 100...200 {
            let value = Double(hundredths) / 100
            #expect(MonitorAnamorphicDesqueeze.snap(value) == value)
        }
        #expect(MonitorDesqueezePreset.matching(1.32) == nil)
        #expect(MonitorDesqueezePreset.matching(1.34) == nil)
        #expect(MonitorAnamorphicDesqueeze.snap(1.005) == 1.01)
        #expect(MonitorAnamorphicDesqueeze.snap(1.335) == 1.34)
        #expect(MonitorAnamorphicDesqueeze.snap(.nan) == 1.33)
        #expect(MonitorAnamorphicDesqueeze.label(1.337) == "1.34×")
    }

    @Test func desqueezeNeverManufacturesUnknownSourceGeometry() {
        let absent: [Double?] = [nil, 0, -1, .infinity, .nan]
        for value in absent {
            #expect(MonitorAnamorphicDesqueeze.aspect(sourceAspect: value, enabled: true,
                factor: 2, direction: .horizontal) == nil)
        }
        #expect(MonitorAnamorphicDesqueeze.aspect(sourceAspect: 2, enabled: true,
            factor: 2, direction: .horizontal) == 4)
        #expect(MonitorAnamorphicDesqueeze.aspect(sourceAspect: 2, enabled: true,
            factor: 2, direction: .vertical) == 1)
        #expect(MonitorAnamorphicDesqueeze.aspect(sourceAspect: 2, enabled: false,
            factor: 2, direction: .horizontal) == 2)
    }
}
