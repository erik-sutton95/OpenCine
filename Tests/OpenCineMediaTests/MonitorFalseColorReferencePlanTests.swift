import Foundation
import OpenCineMedia
import Testing

@Suite struct MonitorFalseColorReferencePlanTests {
    @Test func rec709RulerKeepsTheGrayZoneAndEverySecondStop() {
        let plan = MonitorFalseColorReferencePlan(scale: .sceneStops, transfer: .rec709, clipByte: 255)
        #expect(plan.markers.map(\.label) == ["−6", "−4", "−2", "18%", "clip"])
        let gray = plan.segments.first { $0.band.label == "18%" }
        #expect(gray?.lowerFraction == 8.0 / 12)
        #expect(gray?.upperFraction == 9.0 / 12)
        #expect(ScopeAnchors.clipShelfCodes == 7)
        let encoded = 248.0 / 255
        let linear = pow((encoded + 0.099) / 1.099, 1 / 0.45)
        #expect(abs(plan.clipStops - log2(linear / 0.18)) < 1e-12)
        #expect(plan.markers.first?.fraction == 2.5 / 12)
    }
    @Test func anIreRulerUsesTheReadThroughLooksSignalAndHasNoStopMarkers() {
        let plan = MonitorFalseColorReferencePlan(scale: .ire, transfer: .nlog, clipByte: 180,
            lookCurve: [0, 0.6, 1, 1], readThroughLook: true)
        #expect(plan.markers.isEmpty)
        let gray = plan.segments.first { $0.band.label == "18%MG" }
        #expect(gray?.lowerFraction == 0.38)
        #expect(gray?.upperFraction == 0.42)
        #expect(plan.segments.allSatisfy { (0...1).contains($0.lowerFraction) && (0...1).contains($0.upperFraction) })
    }
}
