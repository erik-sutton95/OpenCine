import Foundation
import OpenCineCore
import OpenCineMotion
import Testing

/// Kotlin GimbalProgramPlaybackTest has the same scenario names and manual instants.
@Suite struct GimbalProgramPlaybackTests {
    private let a = GimbalWaypoint(yawDeg: 0, pitchDeg: 0, zoom: 1)
    private let b = GimbalWaypoint(yawDeg: 20, pitchDeg: 0, zoom: 1)
    private var program: GimbalProgram { .init(a: a, b: b, durationAB: 2) }
    private func at(_ seconds: Double) -> MonotonicInstant { .init(.seconds(seconds)) }
    private func playback(_ program: GimbalProgram? = nil) throws -> GimbalProgramPlayback {
        try #require(GimbalProgramPlayback(program: program ?? self.program,
            capabilities: .testGimbal, countdown: .seconds(3), at: .zero))
    }

    @Test func countdownCancelRetiresInitialAndAllFutureTargets() throws {
        var move = try playback()
        #expect(move.step(at: .zero).target == a)
        #expect(move.state.countdown == 3)
        #expect(move.pause(at: at(1)) == false)
        #expect(move.step(at: at(1)).target == nil)
        #expect(move.state.countdown == 2)
        #expect(move.step(at: at(2)).target == nil)
        #expect(move.state.countdown == 1)
        move.cancel()
        #expect(move.state == .idle)
        #expect(move.step(at: at(100)).target == nil)
        #expect(!move.step(at: at(200)).finished)
    }

    @Test func pauseBudgetUsesTapTimeAndIgnoresPausedWallTime() throws {
        var move = try playback()
        _ = move.step(at: .zero)
        #expect(move.step(at: at(3)).target == a)
        #expect(move.step(at: at(3.5)).target?.yawDeg == 5)
        #expect(move.pause(at: at(3.75)) == true)
        #expect(move.state.elapsed == 0.75)
        #expect(move.step(at: at(30)).target == nil)
        #expect(move.state.elapsed == 0.75)
        #expect(move.resume(at: at(40)) == true)
        #expect(move.step(at: at(40.25)).target?.yawDeg == 10)
        #expect(move.step(at: at(41.25)) == .init(target: b, finished: true))
    }

    @Test func loopEndAndLateTickPreservePassDirection() throws {
        var looping = program; looping.loop = true
        var move = try playback(looping)
        _ = move.step(at: .zero)
        #expect(move.step(at: at(5)).target == b)
        #expect(move.state.reversing && move.state.elapsed == 0)
        #expect(move.step(at: at(7)).target == a)
        #expect(!move.state.reversing && move.state.elapsed == 0)
        #expect(move.step(at: at(12)).target?.yawDeg == 10)
        #expect(!move.state.reversing && move.state.elapsed == 1)
        #expect(move.step(at: at(14)).target?.yawDeg == 10)
        #expect(move.state.reversing && move.state.elapsed == 1)
        #expect(move.state.running)
    }

    @Test func finiteEndEmitsLastTargetOnce() throws {
        var move = try playback()
        _ = move.step(at: .zero)
        #expect(move.step(at: at(30)) == .init(target: b, finished: true))
        #expect(!move.state.running && move.state.elapsed == 2)
        #expect(move.step(at: at(31)) == .init())
        #expect(move.resume(at: at(32)) == false)
    }

    @Test func backwardsClockConsumesNoBudget() throws {
        var move = try playback()
        _ = move.step(at: .zero)
        _ = move.step(at: at(4))
        #expect(move.step(at: at(3)).target?.yawDeg == 10)
        #expect(move.state.elapsed == 1)
        #expect(move.pause(at: at(3)) == true)
        #expect(move.resume(at: at(3)) == true)
        #expect(move.step(at: at(4.5)).target?.yawDeg == 15)
    }

    @Test func admissionRequiresDeclaredAxesBoundsAndFiniteDurations() {
        var withoutZoom = MotionCapabilities.testGimbal; withoutZoom.axes.remove(.zoom)
        var zoom = program; zoom.b?.zoom = 2
        #expect(GimbalProgramPlayback(program: zoom, capabilities: withoutZoom, countdown: .seconds(3), at: .zero) == nil)
        var outside = program; outside.b?.yawDeg = 300
        #expect(GimbalProgramPlayback(program: outside, capabilities: .testGimbal, countdown: .seconds(3), at: .zero) == nil)
        var invalid = program; invalid.durationAB = .nan
        #expect(GimbalProgramPlayback(program: invalid, capabilities: .testGimbal, countdown: .seconds(3), at: .zero) == nil)
        invalid = program; invalid.smoothness = .infinity
        #expect(GimbalProgramPlayback(program: invalid, capabilities: .testGimbal, countdown: .seconds(3), at: .zero) == nil)
        #expect(GimbalProgramPlayback(program: program, capabilities: .testGimbal, countdown: .seconds(-1), at: .zero) == nil)
    }

    @Test func smoothedPathUsesExistingCurveWithoutChangingDuration() throws {
        var smooth = program
        smooth.c = .init(yawDeg: 20, pitchDeg: 20, zoom: 1)
        smooth.durationBC = 3; smooth.smoothness = 0.7
        var move = try playback(smooth)
        _ = move.step(at: .zero)
        let curve = try #require(GimbalProgramCurve(program: smooth))
        for time in [0.0, 0.5, 1, 1.5, 2, 3, 4, 5] {
            #expect(move.step(at: at(3 + time)).target == curve.position(at: time))
        }
        #expect(!move.state.running && move.state.elapsed == 5)
    }

    @Test func countdownDeadlineDoesNotRoundToTargetCadence() throws {
        var move = try playback()
        _ = move.step(at: .init(.milliseconds(2990)))
        #expect(move.nextDelay(upTo: .milliseconds(33)) == .milliseconds(10))
        _ = move.step(at: at(3))
        #expect(move.state.countdown == nil)
        #expect(move.nextDelay(upTo: .milliseconds(33)) == .milliseconds(33))
    }
}
