import Testing
@testable import OpenCineMotion

/// Programmed zoom: the path visits every saved amount and the engine hands out its demand.
@Suite struct GimbalZoomPathTests {
    private var abc: GimbalProgram {
        .init(a: .init(yawDeg: 0, pitchDeg: 0, zoom: 1),
            b: .init(yawDeg: 20, pitchDeg: 0, zoom: 3),
            c: .init(yawDeg: 30, pitchDeg: 0, zoom: 2), durationAB: 3, durationBC: 2)
    }

    @Test func pathRetainsBAndReanchorsToMeasuredZoomOnResume() {
        let path = GimbalZoomPath(program: program(from: 3, to: 6, c: 4))
        #expect(path.nativeDemand(at: 1.25).command == .track(4.5))
        #expect(path.nativeDemand(at: 2.5).command == .track(6))
        #expect(path.nativeDemand(at: 3.5).command == .track(5))
        #expect(path.nativeDemand(at: 4.5).command == .track(4))
        let resumed = path.remaining(after: 1.5, from: 5.2, quantized: true)
        #expect(resumed.legs[0].duration == 1)
        #expect(resumed.nativeDemand(at: 0).command == .track(5.2))
        #expect(resumed.nativeDemand(at: 0.5).command == .track(5.6))
        #expect(resumed.nativeDemand(at: 1).command == .track(6))
    }

    @Test func enginePreservesEndpointsThroughLoopsAndRetiresTargetsOnPause() {
        let a = GimbalWaypoint(yawDeg: 0, pitchDeg: 0, zoom: 3)
        var value = program(from: 3, to: 6, c: 4)
        value.loop = true
        value.smoothness = 0.5
        var engine = GimbalMoveEngine()
        #expect(engine.start(program: value, live: a) == true)
        var positions: [Double] = []
        for _ in 0..<2400 {
            _ = engine.tick(dt: 0.01, live: a)
            if case .track(let factor) = engine.consumeNativeZoomDemand()?.command { positions.append(factor) }
        }
        #expect(engine.running)
        #expect(positions.contains(6))
        #expect(positions.contains(4))
        #expect(positions.contains(3))
        #expect(zip(positions, positions.dropFirst()).contains { $1 > $0 })
        #expect(zip(positions, positions.dropFirst()).contains { $1 < $0 })
        #expect(engine.pause(live: a) == true)
        #expect(engine.nativeZoomDemand == nil)
        engine.cancel()
        #expect(engine.nativeZoomDemand == nil)
    }

    @Test func finalSavedAmountIsRetainedDuringVerification() {
        var engine = GimbalMoveEngine()
        let a = GimbalWaypoint(yawDeg: 0, pitchDeg: 0, zoom: 3)
        #expect(engine.start(program: program(from: 3, to: 6), live: a) == true)
        var reachedEnd = false
        for _ in 0..<1000 {
            _ = engine.tick(dt: 0.01, live: a)
            if engine.readout(live: a)?.phase == "VERIFY" {
                #expect(engine.nativeZoomDemand?.command == .track(6))
                #expect(engine.consumeNativeZoomDemand()?.command == .track(6))
                reachedEnd = true
            }
            if !engine.running { break }
        }
        #expect(reachedEnd)
        #expect(!engine.running)
    }

    @Test func exactZoomAmountsSurviveRoundedPathsAndMeasuredResume() {
        var saved = abc
        saved.smoothness = 1
        let path = GimbalZoomPath(program: saved)
        #expect(abs(path.position(at: 1.45) - 2) < 1e-9)
        #expect(path.position(at: 2.98) == 3, "Look-ahead stops at B rather than skipping its zoom")
        #expect(path.position(at: 4.98) == 2)
        let resumed = path.remaining(after: 1.45, from: 2.4, quantized: true)
        #expect(resumed.position(at: 0, lookAhead: 0) == 2.4)
        #expect(abs(resumed.legs[0].duration - 1.6) < 1e-9)
        #expect(resumed.legs[1].duration == 2)
        #expect(resumed.position(at: 1.59) == 3)
        #expect(resumed.end == 2)
        let beforeB = path.remaining(after: 2.96, from: 2.9, quantized: false)
        #expect(abs(beforeB.legs[0].duration - 0.04) < 1e-9)
        #expect(abs(beforeB.duration - 2.04) < 1e-9)
        let lateResume = path.remaining(after: 4, from: 2.7, quantized: false)
        #expect(lateResume.legs.count == 1)
        #expect(lateResume.duration == 1)
        #expect(lateResume.position(at: 0, lookAhead: 0) == 2.7)
    }

    private func program(from: Double, to: Double, c: Double? = nil) -> GimbalProgram {
        .init(a: .init(yawDeg: 0, pitchDeg: 0, zoom: from), b: .init(yawDeg: 0, pitchDeg: 0, zoom: to),
            c: c.map { .init(yawDeg: 0, pitchDeg: 0, zoom: $0) }, durationAB: 2.5, durationBC: 2)
    }
}
