import Testing

import OpenCineCore
@testable import OpenCineMedia

@Suite struct ShutterAngleTests {
    @Test func ladderRunsFromFivePointSixToThreeSixty() {
        #expect(ShutterAngle.labels.first == "5.6°")
        #expect(ShutterAngle.labels.last == "360°")
        #expect(ShutterAngle.labels.contains("180°"))
        #expect(ShutterAngle.labels.contains("86.4°"))
        #expect(ShutterAngle.labels.contains("172°"))
        #expect(ShutterAngle.parse("180°") == 180)
        #expect(ShutterAngle.parse("5.6°") == 5.6)
        #expect(ShutterAngle.label(180) == "180°")
        #expect(ShutterAngle.label(5.6) == "5.6°")
        #expect(ShutterAngle.label(11.2) == "11.2°")
    }

    @Test func oneEightyIsAHalfTurnAtAnyFps() {
        #expect(ShutterAngle.denom(degrees: 180, fps: 24) == 48)
        #expect(ShutterAngle.denom(degrees: 180, fps: 25) == 50)
        #expect(ShutterAngle.denom(degrees: 180, fps: 30) == 60)
        #expect(ShutterAngle.denom(degrees: 180, fps: 60) == 120)
        #expect(ShutterAngle.denom(degrees: 360, fps: 24) == 24)
        #expect(ShutterAngle.denom(degrees: 5.6, fps: 24) == 1_543)
    }

    @Test func liveSpeedSnapsToTheNearestStop() {
        #expect(ShutterAngle.nearestLabel(denom: 48, fps: 24) == "180°")
        #expect(ShutterAngle.nearestLabel(denom: 50, fps: 24) == "172°")
        #expect(ShutterAngle.nearestLabel(denom: 24, fps: 24) == "360°")
        #expect(ShutterAngle.nearestLabel(denom: 50, fps: 25) == "180°")
    }

    /// MULTI-03 F4: unknown stays unknown instead of 180° or a 24 fps guess.
    @Test func unknownShutterOrRateHasNoAngle() {
        #expect(ShutterAngle.degrees(denom: 0, fps: 24) == nil)
        #expect(ShutterAngle.degrees(denom: -1, fps: 24) == nil)
        #expect(ShutterAngle.degrees(denom: 48, fps: 0) == nil)
        #expect(ShutterAngle.nearestLabel(denom: 0, fps: 24) == nil)
        #expect(ShutterAngle.nearestLabel(denom: 48, fps: 0) == nil)
        #expect(ShutterAngle.degrees(denom: 48, fps: 24) == 180)
    }

    @Test func sendSnapsToTheCameraList() {
        #expect(
            ShutterAngle.denom(degrees: 180, fps: 24, available: [25, 50, 100, 200])
                == 50)
        #expect(ShutterAngle.denom(degrees: 180, fps: 24, available: []) == 48)
        #expect(ShutterAngle.effectiveFps(0) == 24)
        #expect(ShutterAngle.effectiveFps(60) == 60)
    }

    /// 180 degrees at each rate: the exact 1/N when the body lists it, else the nearest listed.
    @Test func oneEightyPerRatePinsTheSpeed() {
        let luna = [8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400,
            320, 250, 200, 160, 125, 100, 80, 60, 50, 40, 30, 25, 15, 10, 5]
        let pocket3 = [8000, 6400, 4000, 3200, 2000, 1600, 1000, 800, 500, 400, 250, 200, 125, 120,
            100, 60, 50, 48, 40, 30, 25, 24]
        for (fps, exact, onLuna, onPocket3) in [(24, 48, 50, 48), (25, 50, 50, 50), (30, 60, 60, 60),
            (60, 120, 125, 120), (120, 240, 250, 250)] {
            #expect(ShutterAngle.denom(degrees: 180, fps: fps) == exact)
            #expect(ShutterAngle.denom(degrees: 180, fps: fps, available: luna) == onLuna)
            #expect(ShutterAngle.denom(degrees: 180, fps: fps, available: pocket3) == onPocket3)
        }
        #expect(ShutterAngle.denom(degrees: 180, fps: 120, available: luna + [240]) == 240)
    }

    /// Owner 2026-10-20 (Luna, Angle 180 at 30p, shutter priority): "0.0108°". A single-precision
    /// 1/60 readback is that speed, and its angle comes from the whole duration.
    @Test func anInexactReadbackIsItsSpeedAndAngle() throws {
        for denom in [48, 50, 60, 120, 125, 240, 250, 1000, 8000] {
            let inexact = Double(Float(1.0 / Double(denom)))
            #expect(HostShutterAngle.readback(seconds: inexact) == Rational(1, denom))
        }
        #expect(HostShutterAngle.readback(seconds: 2) == Rational(2))
        #expect(HostShutterAngle.readback(seconds: 0.4) == Rational(2, 5))
        #expect(HostShutterAngle.readback(seconds: 0) == nil)
        // Fast speeds are within half a step of 1/N by construction; a slow non-reciprocal keeps
        // its value, and its angle is the whole duration, never its denominator alone.
        #expect(HostShutterAngle.readback(seconds: 0.0123) == Rational(1, 81))
        let measured = try #require(HostShutterAngle.readback(seconds: 0.15))
        #expect(measured == Rational(3, 20))
        #expect(HostShutterAngle.reported(seconds: Rational(1, 60), framesPerSecond: 30) == 180)
        let reading = try #require(HostShutterAngle.reported(seconds: measured, framesPerSecond: 5))
        #expect(abs(reading - 270) < 1e-9)
        #expect(HostShutterAngle.reported(seconds: Rational(1, 60), framesPerSecond: nil) == nil)
    }

    @Test func achievedTellsTheRealAngleOnlyWhenItDiffers() {
        #expect(ShutterAngle.achieved(preferredDegrees: 180, denom: 250, fps: 120) == "1/250 (172.8°)")
        #expect(ShutterAngle.achieved(preferredDegrees: 180, denom: 240, fps: 120) == nil)
        #expect(ShutterAngle.achieved(preferredDegrees: 180, denom: 60, fps: 30) == nil)
        #expect(ShutterAngle.achieved(preferredDegrees: 180, denom: 250, fps: 0) == nil)
    }

    @Test func formatRematchRequiresEstablishedManualVideoAndPreservesQueuedIntent() {
        #expect(ShutterAngle.rematchesFormat(
            usesAngle: true, manual: true, isPhoto: false, previousFps: 25, nextFps: 50))
        #expect(!ShutterAngle.rematchesFormat(
            usesAngle: true, manual: false, isPhoto: false, previousFps: 25, nextFps: 50))
        #expect(!ShutterAngle.rematchesFormat(
            usesAngle: true, manual: true, isPhoto: true, previousFps: 25, nextFps: 50))
        #expect(!ShutterAngle.rematchesFormat(
            usesAngle: false, manual: true, isPhoto: false, previousFps: 25, nextFps: 50))
        #expect(!ShutterAngle.rematchesFormat(
            usesAngle: true, manual: true, isPhoto: false, previousFps: 0, nextFps: 50))
        #expect(!ShutterAngle.rematchesFormat(
            usesAngle: true, manual: true, isPhoto: false, previousFps: 50, nextFps: 50))
        #expect(ShutterAngle.rematchesFormat(
            usesAngle: true, manual: true, isPhoto: false, previousFps: 50, nextFps: 50,
            alreadyPending: true))
    }
}
