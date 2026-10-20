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

    /// The Luna wheel: no 1/48, 1/120 or 1/240.
    private static let luna = [8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640,
        500, 400, 320, 250, 200, 160, 125, 100, 80, 60, 50, 40, 30, 25, 15, 10, 5]

    /// Owner 2026-10-20: Angle 180 at 4K120 read "172.8°". The session reports the emulated angle
    /// it really makes (1/250 at 120 fps); the operator's 180 holds while the camera holds it.
    @Test func theOperatorsAngleHoldsThroughTheNearestLegalSpeed() {
        func label(_ shutter: ShutterValue, _ fps: Int) -> String {
            CaptureNativeReadoutPresentation.shutterAngle(common: shutter, frameRate: Rational(fps),
                available: Self.luna, preferredAngle: 180)
        }
        #expect(label(.angle(172.8), 120) == "180°")
        #expect(label(.angle(172.8), 24) == "180°")
        #expect(label(.angle(172.8), 60) == "180°")
        #expect(label(.angle(180), 30) == "180°")
        #expect(label(.angle(180), 25) == "180°")
        #expect(label(.duration(Rational(1, 250)), 120) == "180°")
        // A speed set elsewhere is still told honestly.
        #expect(label(.angle(360), 30) == "360°")
        #expect(label(.duration(Rational(1, 1000)), 30) == "11.2°")
    }

    /// Owner 2026-10-20: changing the rate flashed "42°" until the camera confirmed. A rate and a
    /// speed from two moments are no angle; while settling the operator's angle holds.
    @Test func noTransientAngleWhileAFormatOrShutterChangeSettles() {
        func label(_ shutter: ShutterValue, _ fps: Int, settling: Bool) -> String {
            CaptureNativeReadoutPresentation.shutterAngle(common: shutter, frameRate: Rational(fps),
                available: Self.luna, preferredAngle: 180, settling: settling)
        }
        // 30 -> 120: the new rate reported before the re-sent 1/250 lands.
        #expect(label(.duration(Rational(1, 60)), 120, settling: true) == "180°")
        #expect(label(.angle(720), 120, settling: true) == "180°")
        // 120 -> 30: the old 1/250 at the new rate is 43.2 degrees.
        #expect(label(.duration(Rational(1, 250)), 30, settling: true) == "180°")
        #expect(label(.angle(43.2), 30, settling: true) == "180°")
        #expect(label(.duration(Rational(1, 250)), 30, settling: false) == "45°")
        #expect(CaptureNativeReadoutPresentation.shutterAngle(common: .duration(Rational(1, 60)),
            frameRate: nil, available: Self.luna, preferredAngle: 180, settling: true) == "180°")
    }

    @Test func theAchievedSpeedIsToldOnlyWhenItIsNotExact() {
        func achieved(_ shutter: ShutterValue, _ fps: Int, settling: Bool = false) -> String? {
            CaptureNativeReadoutPresentation.shutterAngleAchieved(common: shutter, frameRate: Rational(fps),
                available: Self.luna, preferredAngle: 180, settling: settling)
        }
        #expect(achieved(.angle(172.8), 120) == "1/250 (172.8°)")
        #expect(achieved(.duration(Rational(1, 50)), 24) == "1/50 (172.8°)")
        #expect(achieved(.angle(180), 30) == nil)
        #expect(achieved(.angle(172.8), 120, settling: true) == nil)
        #expect(achieved(.angle(360), 30) == nil, "not holding the operator's angle")
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
