#if canImport(CoreImage) && canImport(CoreVideo) && canImport(Metal)
    import CoreVideo
    import Foundation
    import OpenCineMedia
    import XCTest

    @testable import OpenCineApple

    private final class CadenceClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: CFAbsoluteTime = 100
        var now: CFAbsoluteTime { lock.withLock { value } }
        func set(_ value: CFAbsoluteTime) { lock.withLock { self.value = value } }
    }

    private final class BundleCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }

    /// SIMULATED frames on a manual clock. Playback scopes follow the clip: a 25 fps clip with
    /// one scope is measured on every frame (the 25 Hz budget), not on every other one.
    final class MonitorAssistEngineScopeCadenceTests: XCTestCase {
        private func frame() throws -> CVPixelBuffer {
            var created: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 36, kCVPixelFormatType_32BGRA, nil, &created)
            let buffer = try XCTUnwrap(created)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 120, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return buffer
        }

        private func measuredFrames(arrivals: [CFAbsoluteTime], scopes: Int) throws -> Int {
            let clock = CadenceClock()
            let queue = DispatchQueue(label: "cadence-test")
            let engine = MonitorAssistEngine(
                configuration: .init(), scopeNow: { clock.now }, queue: queue)
            var policy = MonitorAssistPolicy()
            policy.waveform = true
            if scopes > 1 { policy.histogram = true }
            if scopes > 2 { policy.vectorscope = true; policy.parade = true }
            let bundles = BundleCount()
            let buffer = try frame()
            for time in arrivals {
                clock.set(time)
                let presented = expectation(description: "frame")
                engine.submit(buffer, effects: policy, transfer: .rec709) { result in
                    if result.bundle != nil { bundles.add() }
                    if result.shouldPresent { presented.fulfill() }
                }
                wait(for: [presented], timeout: 10)
                queue.sync {}
            }
            queue.sync {}
            return bundles.count
        }

        func testA25FpsClipIsMeasuredOnEveryFrameDespiteJitter() throws {
            // 25 fps arrivals, every other one a millisecond early.
            let arrivals: [CFAbsoluteTime] = (0..<50).map { index in
                let early: Double = index % 2 == 1 ? 0.001 : 0
                return 100 + Double(index) * 0.04 - early
            }
            XCTAssertEqual(try measuredFrames(arrivals: arrivals, scopes: 1), 50)
        }

        func testAFastSourceStillHoldsTheScopeBudget() throws {
            // 120 Hz arrivals for one second never exceed the 25 Hz budget.
            let arrivals: [CFAbsoluteTime] = (0..<120).map { 100 + Double($0) / 120 }
            let measured = try measuredFrames(arrivals: arrivals, scopes: 1)
            XCTAssertLessThanOrEqual(measured, 26)
            XCTAssertGreaterThanOrEqual(measured, 23)
        }

        func testALateTapDoesNotCatchUp() {
            let interval = 0.04
            let next = MonitorAssistEngine.nextScopeDeadline(now: 10, deadline: 9, interval: interval)
            XCTAssertEqual(next, 10.04, accuracy: 1e-9)
        }

        func testATapLateEnoughToOpenTheNextWindowRestartsFromNow() throws {
            // A 120 Hz source whose tap lands 0.8 intervals late is not due again on the next
            // frame: the deadline restarts from that tap.
            let interval = 0.04
            let late = 100 + interval * 0.8
            let next = MonitorAssistEngine.nextScopeDeadline(now: late, deadline: 100, interval: interval)
            XCTAssertFalse(MonitorAssistEngine.scopeDue(now: late + 1.0 / 120, deadline: next, interval: interval))
            XCTAssertEqual(next, late + interval, accuracy: 1e-9)
            // An ordinary jittered tap keeps the grid.
            let onTime = MonitorAssistEngine.nextScopeDeadline(now: 100.005, deadline: 100, interval: interval)
            XCTAssertEqual(onTime, 100.04, accuracy: 1e-9)
        }
    }
#endif
