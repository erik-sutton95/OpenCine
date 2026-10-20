import OpenCineAppKit
import OpenCineCameraControls
import OpenCineCameraVocabulary
import OpenCineCore
import Testing

@Suite struct CaptureNativeReadoutPresentationTests {
    @Test func emulatedAngleUsesOnlyKnownCommonShutterAndCadence() {
        func label(_ shutter: ShutterValue?, _ rate: Rational?) -> String {
            CaptureNativeReadoutPresentation.shutterAngle(common: shutter, frameRate: rate,
                available: [25, 50, 100], preferredAngle: 180)
        }
        #expect(label(nil, Rational(25)) == "--")
        #expect(label(.duration(Rational(1, 50)), nil) == "1/50")
        #expect(label(.duration(Rational(1, 100)), Rational(25)) == "90°")
        #expect(label(.duration(Rational(1, 50)), Rational(24)) == "180°")
        #expect(label(.duration(Rational(2)), Rational(25)) == "2s")
        #expect(label(.angle(144), nil) == "144°")
        #expect(label(.duration(Rational(1, 50)), Rational(0)) == "1/50")
        #expect(label(.duration(Rational(1, Int(Int32.max))), Rational(25)) == "1/2147483647")
    }

    @Test func nativeFocusStrategiesDoNotReplaceTheCommonBaseMode() {
        for native in [FocusOption.productShowcase, .subjectLock, .registeredPriority] {
            #expect(CaptureNativeReadoutPresentation.focus(common: .continuous, native: native) == native.chip)
            #expect(CaptureNativeReadoutPresentation.focus(common: nil, native: native) == native.chip)
            #expect(CaptureNativeReadoutPresentation.focus(common: .single, native: native) == "AF-S")
            #expect(CaptureNativeReadoutPresentation.focus(common: .manual, native: native) == "MF")
        }
        #expect(CaptureNativeReadoutPresentation.focus(common: nil, native: nil) == "--")
        #expect(CaptureNativeReadoutPresentation.focus(common: nil, native: .single) == "--")
        #expect(CaptureNativeReadoutPresentation.focus(common: nil, native: .continuousDefault) == "--")
        #expect(CaptureNativeReadoutPresentation.focus(common: .continuous, native: .single) == "AF-C")
        #expect(CaptureNativeReadoutPresentation.focus(common: .single, native: nil) == "AF-S")
    }

    /// Behavior audit PIA-269: until the measured iris arrives the APERTURE tile reads the requested
    /// strategy (Action 6), as the standalone app did, never a dash.
    @Test func apertureFallsBackToTheRequestedStrategyUntilTheIrisIsMeasured() {
        #expect(CaptureNativeReadoutPresentation.aperture(common: nil, strategy: .starburst) == "Starburst f/4")
        #expect(CaptureNativeReadoutPresentation.aperture(common: nil, strategy: nil) == "--")
        #expect(CaptureNativeReadoutPresentation.aperture(common: 2.8, strategy: .starburst)
            == MonitorCapturePresentation.label(.aperture(2.8)))
    }
}
