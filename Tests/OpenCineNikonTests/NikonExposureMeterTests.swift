import Foundation
import OpenCineCameraVocabulary
import Testing

@testable import OpenCineNikon

/// The body's exposure indicator feeds the shared exposure meter every app draws: the needle in
/// stops while the indicator is lit, unknown before the first report and while it is unlit.
@Suite struct NikonExposureMeterTests {
    private func snapshot(sixths: Int8?, lit: Bool?) -> PTPCameraPropertySnapshot {
        var snapshot = PTPCameraPropertySnapshot()
        if let sixths {
            snapshot = snapshot.applying(
                property: .exposureIndicateStatus, data: Data([UInt8(bitPattern: sixths)]))
        }
        if let lit {
            // The body reports 0 while the indicator is lit.
            snapshot = snapshot.applying(property: .exposureIndicateLightup, data: Data([lit ? 0 : 1]))
        }
        return snapshot
    }

    @Test func aLitIndicatorReadsItsSixthStopsOnTheSharedMeter() {
        let reading = snapshot(sixths: 4, lit: true).exposureMeter
        #expect(reading == ExposureMeterReading(stops: 4.0 / 6))
        #expect(reading.label == "+0.7")
        #expect(reading.accessibilityValue == "Camera exposure +0.7 EV")
        let under = snapshot(sixths: -9, lit: true).exposureMeter
        #expect(under.stops == -1.5)
        #expect(under.label == "\u{2212}1.5")
    }

    @Test func anIndicatorBeyondTheScaleKeepsItsValueAndPinsTheNeedle() {
        let reading = snapshot(sixths: 60, lit: true).exposureMeter
        #expect(reading.stops == 10)
        #expect(reading.needleFraction == 1)
    }

    @Test func anUnreportedOrUnlitIndicatorIsUnknownNotZero() {
        #expect(snapshot(sixths: nil, lit: nil).exposureMeter.stops == nil)
        #expect(snapshot(sixths: nil, lit: true).exposureMeter.stops == nil)
        let unlit = snapshot(sixths: 3, lit: false).exposureMeter
        #expect(unlit.stops == nil)
        #expect(unlit.label == "\u{2014}")
        #expect(unlit.accessibilityValue == "Unavailable, waiting for camera EV")
        // A lit state the body has not reported yet keeps the value it did report.
        #expect(snapshot(sixths: 3, lit: nil).exposureMeter.stops == 0.5)
    }
}
