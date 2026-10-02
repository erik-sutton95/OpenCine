import Foundation
import OpenCineCore
import OpenCineMotion
import Testing

/// OPTIONAL-02 gate: shared motion cannot command coordinates or rates outside what the service
/// declared, and minimum Core does not depend on this product.
@Suite struct MotionSeamTests {
    private let service = MotionCapabilities(
        axes: [.pan, .tilt], frame: .handle, bounds: reach,
        maxRateDegPerSec: 60, feedbackMaxAge: .milliseconds(300), arrivalToleranceDeg: 0.5)

    private func pose(_ yaw: Double, _ pitch: Double, zoom: Double = 1) -> GimbalWaypoint {
        GimbalWaypoint(yawDeg: yaw, pitchDeg: pitch, zoom: zoom, nativePitchDeg: -pitch)
    }

    @Test func targetsExistOnlyInsideTheDeclaredBounds() {
        #expect(service.target(pose(0, 0)) != nil)
        #expect(service.target(pose(225, 70)) != nil)
        for outside in [pose(225.01, 0), pose(-48.01, 0), pose(0, 70.01), pose(0, -44.01), pose(.nan, 0)] {
            #expect(service.target(outside) == nil)
        }
        var noTilt = service
        noTilt.axes = [.pan]
        #expect(noTilt.target(pose(0, 0)) == nil)
    }

    /// Fuzzed head looks from fuzzed in-bounds origins: every head-track target is a target.
    @Test func headTrackNeverLeavesTheDeclaredBounds() {
        var rng = SplitMix(seed: 0x5EED)
        for _ in 0..<500 {
            var track = HeadTrackNative(bounds: service.bounds)
            let origin = pose(rng.next(in: reach.pan), rng.next(in: reach.tilt))
            #expect(track.center(pose: origin) == .centered)
            for _ in 0..<20 {
                let look = track.target(
                    lookRightDeg: rng.next(in: -720...720), lookUpDeg: rng.next(in: -270...270))
                #expect(look.flatMap(service.target) != nil)
            }
        }
    }

    /// Fuzzed programs: an admitted program's straight and smoothed paths stay targetable and
    /// within the declared rate.
    @Test func admittedProgramsStayInBoundsAndUnderTheRate() {
        var rng = SplitMix(seed: 0xC0FFEE)
        var admitted = 0
        for _ in 0..<500 {
            let program = GimbalProgram(
                a: pose(rng.next(in: reach.pan), rng.next(in: reach.tilt)),
                b: pose(rng.next(in: reach.pan), rng.next(in: reach.tilt)),
                c: pose(rng.next(in: reach.pan), rng.next(in: reach.tilt)),
                durationAB: rng.next(in: 0.5...12), durationBC: rng.next(in: 0.5...12),
                smoothness: rng.next(in: 0.01...1))
            guard service.admits(program) else { continue }
            admitted += 1
            let curve = GimbalProgramCurve(program: program)!
            let samples = curve.samples(count: 200)
            #expect(samples.allSatisfy { service.target($0) != nil })
            let dt = curve.duration / 199
            for (from, to) in zip(samples, samples.dropFirst()) {
                #expect(GimbalPath.angularDistance(from, to) <= 60 * dt + 1e-6)
            }
        }
        #expect(admitted > 50)
    }

    @Test func programsNeedEveryPointInBoundsAZoomAxisAndTheRate() {
        let a = pose(0, 0)
        #expect(service.admits(GimbalProgram(a: a, b: pose(30, 0), durationAB: 0.5)))
        #expect(!service.admits(GimbalProgram(a: a, b: pose(31, 0), durationAB: 0.5)), "62 deg/s")
        #expect(!service.admits(GimbalProgram(a: a)))
        #expect(!service.admits(GimbalProgram(a: a, b: pose(300, 0))))
        let zoom = GimbalProgram(a: a, b: pose(10, 0, zoom: 2))
        #expect(!service.admits(zoom))
        var zooming = service
        zooming.axes.insert(.zoom)
        zooming.maxRateDegPerSec = nil
        #expect(zooming.admits(zoom))
        #expect(zooming.admits(GimbalProgram(a: a, b: pose(200, 0), durationAB: 0.5)), "camera paces")
    }

    @Test func feedbackMustBeFreshValidAndReportedByTheCamera() {
        let at = MonotonicInstant(.seconds(10))
        let reading = ObservedValue(pose(10, 5), origin: .cameraReported, at: at)
        #expect(service.feedback(reading, at: at + .milliseconds(300)) == pose(10, 5))
        #expect(service.feedback(reading, at: at + .milliseconds(301)) == nil)
        var estimated = reading
        estimated.origin = .imageEstimated
        #expect(service.feedback(estimated, at: at) == nil)
        var invalid = reading
        invalid.validity = .invalid(reason: "recentering")
        #expect(service.feedback(invalid, at: at) == nil)
        #expect(service.feedback(.unknown, at: at) == nil)
    }

    @Test func arrivalUsesTheDeclaredTolerance() throws {
        let target = try #require(service.target(pose(10, 0)))
        #expect(service.hasArrived(pose(10.3, 0.3), at: target))
        #expect(!service.hasArrived(pose(10.4, 0.4), at: target))
    }

    /// gimbal = the service drives pan and tilt; head tracking also needs a camera-reported pose.
    /// No service is no gimbal; unknown pose support keeps the base.
    @Test func layoutProjectionDerivesGimbalAndHeadTracking() {
        let none = CapabilitySnapshot()
        var base = MonitorLayoutCapabilities()
        base.gimbal = true
        base.headTracking = true
        base.timecode = true
        #expect(MonitorLayoutCapabilities(none, base: base) == base, "motion not known yet")
        let absent = MonitorLayoutCapabilities(none, motion: nil, base: base)
        #expect(!absent.gimbal && !absent.headTracking && absent.timecode)

        var motion = service
        motion.pose = .supported
        let tracked = MonitorLayoutCapabilities(none, motion: motion)
        #expect(tracked.gimbal && tracked.headTracking)
        motion.pose = .unknown
        #expect(!MonitorLayoutCapabilities(none, motion: motion).headTracking)
        #expect(MonitorLayoutCapabilities(none, motion: motion, base: base).headTracking)
        motion.pose = .unsupported
        let stickOnly = MonitorLayoutCapabilities(none, motion: motion, base: base)
        #expect(stickOnly.gimbal && !stickOnly.headTracking)
        motion.pose = .supported
        motion.axes = [.pan, .zoom]
        let panOnly = MonitorLayoutCapabilities(none, motion: motion, base: base)
        #expect(!panOnly.gimbal && !panOnly.headTracking)
    }

    @Test func boundsContainment() {
        #expect(MotionBounds(pan: -58.5...235, tilt: -57...90).contains(reach))
        #expect(!reach.contains(MotionBounds(pan: -58.5...235, tilt: -57...90)))
    }

    /// Optional means optional: minimum Core and Media never import this product, and it imports
    /// Foundation and OpenCineCore only, naming no manufacturer.
    @Test func importRules() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let brands = try Regex(
            #"\b(dji|osmo|nikon|zcine|insta360|insta|luna|pocket|sony|canon|blackmagic|gopro)\b"#
        ).ignoresCase()
        for target in ["OpenCineCore", "OpenCineMedia", "OpenCineMotion"] {
            let directory = root.appending(path: "Sources/\(target)")
            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "swift" }
            #expect(!files.isEmpty)
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                if target == "OpenCineMotion" {
                    for line in text.split(separator: "\n") where line.hasPrefix("import ") {
                        #expect(["import Foundation", "import OpenCineCore"].contains(line),
                            "\(file.lastPathComponent): \(line)")
                    }
                    #expect(text.firstMatch(of: brands) == nil, "\(file.lastPathComponent) names a brand")
                } else {
                    #expect(!text.contains("OpenCineMotion"), "\(target) depends on OpenCineMotion")
                }
            }
        }
        let manifest = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        #expect(manifest.contains(#".target(name: "OpenCineCore")"#), "Core has no dependencies")
        #expect(manifest.contains(#".target(name: "OpenCineMedia", dependencies: ["OpenCineCore"])"#))
    }
}

/// Deterministic generator so fuzzed gate tests are reproducible.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(next() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
}
