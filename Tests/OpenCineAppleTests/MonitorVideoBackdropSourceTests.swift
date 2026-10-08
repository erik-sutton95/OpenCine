#if os(iOS)
import CoreVideo
import Foundation
import OpenCineApple
import OpenCineMedia
import XCTest

private final class BackdropSourceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    var now: UInt64 { lock.withLock { value } }
    func advance() { lock.withLock { value += MonitorBackdropRenderValues.minimumIntervalNanoseconds } }
}
private final class BackdropSourceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
@MainActor private final class BackdropSourceCheck {
    var calls = 0
    var active = true
}

/// SIMULATED buffers exercise the actual native queue/source gate, not camera pixels.
@MainActor final class MonitorVideoBackdropSourceTests: XCTestCase {
    typealias Renderer = MonitorVideoBackdropRenderer
    private let canvas = CGSize(width: 8, height: 8)
    private func source(admission: (@MainActor @Sendable () -> Bool)? = nil) throws -> MonitorVideoBackdropSource {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA,
            nil, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return .init(buffer: try XCTUnwrap(buffer), effects: .init(),
            frame: CGRect(origin: .zero, size: canvas), clip: CGRect(origin: .zero, size: canvas),
            admission: admission)
    }
    private func renderer(clock: BackdropSourceClock, calls: BackdropSourceCounter,
        operation: Renderer.Operation? = nil) -> Renderer {
        Renderer(products: [.init(radius: 8, saturation: 1)], lookCurves: [:], clock: { clock.now },
            operation: operation ?? { size, _ in
                calls.increment(); return .init(canvasSize: size, images: [:])
            })
    }
    func testPredicateReentryRejectsFalseAndTrueBeforeNativeWork() async throws {
        for reply in [false, true] {
            let clock = BackdropSourceClock(), calls = BackdropSourceCounter()
            let renderer = renderer(clock: clock, calls: calls), old = UUID(), next = UUID()
            let check = BackdropSourceCheck()
            let stale = try source {
                check.calls += 1
                if check.calls == 1 { renderer.activate(next) }
                return reply
            }
            renderer.activate(old)
            let result = await renderer.render(owner: old, canvasSize: canvas) { [stale] }
            XCTAssertNil(result); XCTAssertEqual(calls.value, 0)
            clock.advance()
            let fresh = try source()
            let successor = await renderer.render(owner: next, canvasSize: canvas) { [fresh] }
            XCTAssertTrue(renderer.isCurrent(try XCTUnwrap(successor)))
            XCTAssertEqual(calls.value, 1)
        }
    }
    func testPredicateReentryRejectsFalseAndTrueAfterNativeWork() async throws {
        for reply in [false, true] {
            let clock = BackdropSourceClock(), calls = BackdropSourceCounter()
            let renderer = renderer(clock: clock, calls: calls), old = UUID(), next = UUID()
            let check = BackdropSourceCheck()
            let stale = try source {
                check.calls += 1
                if check.calls == 2 { renderer.activate(next); return reply }
                return true
            }
            renderer.activate(old)
            let result = await renderer.render(owner: old, canvasSize: canvas) { [stale] }
            XCTAssertNil(result); XCTAssertEqual(calls.value, 1)
            clock.advance()
            let fresh = try source()
            let successor = await renderer.render(owner: next, canvasSize: canvas) { [fresh] }
            XCTAssertTrue(renderer.isCurrent(try XCTUnwrap(successor)))
            XCTAssertEqual(calls.value, 2, "Retired native work cannot seed its successor cache")
        }
    }
    func testStaleErrorAdmissionCannotDisableOrClearSuccessor() async throws {
        for reply in [false, true] {
            let clock = BackdropSourceClock(), calls = BackdropSourceCounter()
            let renderer = renderer(clock: clock, calls: calls, operation: { _, _ in calls.increment(); return nil })
            let old = UUID(), next = UUID(), check = BackdropSourceCheck()
            let stale = try source {
                check.calls += 1
                if check.calls == 2 { renderer.activate(next); return reply }
                return true
            }
            renderer.activate(old)
            let result = await renderer.render(owner: old, canvasSize: canvas) { [stale] }
            XCTAssertNil(result)
            clock.advance()
            let fresh = try source()
            let successor = await renderer.render(owner: next, canvasSize: canvas) { [fresh] }
            XCTAssertTrue(renderer.isCurrent(try XCTUnwrap(successor)))
            XCTAssertEqual(calls.value, 2)
        }
    }
    func testSourceEpochRetirementRejectsCachedPixels() async throws {
        let clock = BackdropSourceClock(), calls = BackdropSourceCounter()
        let renderer = renderer(clock: clock, calls: calls), owner = UUID(), check = BackdropSourceCheck()
        let captured = try source { check.active }
        renderer.activate(owner)
        let rendered = await renderer.render(owner: owner, canvasSize: canvas) { [captured] }
        let first = try XCTUnwrap(rendered)
        XCTAssertTrue(renderer.isCurrent(first)); XCTAssertEqual(calls.value, 1)
        check.active = false; clock.advance()
        XCTAssertFalse(renderer.isCurrent(first))
        let retired = await renderer.render(owner: owner, canvasSize: canvas) { [captured] }
        XCTAssertNil(retired); XCTAssertEqual(calls.value, 1)
        renderer.activate(owner); clock.advance()
        let fresh = try source()
        let successor = await renderer.render(owner: owner, canvasSize: canvas) { [fresh] }
        XCTAssertTrue(renderer.isCurrent(try XCTUnwrap(successor)))
        XCTAssertFalse(renderer.isCurrent(first)); XCTAssertEqual(calls.value, 2)
    }
    func testNewItemAndEpochCannotReuseOldNativeIdentityCache() async throws {
        let clock = BackdropSourceClock(), calls = BackdropSourceCounter()
        let renderer = renderer(clock: clock, calls: calls), owner = UUID(), itemOwner = UUID()
        let fixture = try source()
        func captured(revision: UInt64, epoch: UInt64) -> MonitorVideoBackdropSource {
            .init(buffer: fixture.buffer, effects: fixture.effects, frame: fixture.frame, clip: fixture.clip,
                identity: .playback(item: .init(owner: itemOwner, revision: revision), epoch: epoch))
        }
        renderer.activate(owner)
        let first = await renderer.render(owner: owner, canvasSize: canvas) { [captured(revision: 1, epoch: 1)] }
        XCTAssertFalse(try XCTUnwrap(first).isUnchanged)
        clock.advance()
        let nextItem = await renderer.render(owner: owner, canvasSize: canvas) { [captured(revision: 2, epoch: 1)] }
        XCTAssertFalse(try XCTUnwrap(nextItem).isUnchanged)
        clock.advance()
        let nextEpoch = await renderer.render(owner: owner, canvasSize: canvas) { [captured(revision: 2, epoch: 2)] }
        XCTAssertFalse(try XCTUnwrap(nextEpoch).isUnchanged)
        clock.advance()
        let repeated = await renderer.render(owner: owner, canvasSize: canvas) { [captured(revision: 2, epoch: 2)] }
        XCTAssertTrue(try XCTUnwrap(repeated).isUnchanged)
        XCTAssertEqual(calls.value, 3)
    }
    func testReentrantPreparationCannotRenderOrCancelSuccessor() async throws {
        let clock = BackdropSourceClock(), calls = BackdropSourceCounter()
        let renderer = renderer(clock: clock, calls: calls), old = UUID(), next = UUID()
        let captured = try source()
        renderer.activate(old)
        let retired = await renderer.render(owner: old, canvasSize: canvas) {
            renderer.activate(next); return [captured]
        }
        XCTAssertNil(retired); XCTAssertEqual(calls.value, 0)
        clock.advance()
        let successor = await renderer.render(owner: next, canvasSize: canvas) { [captured] }
        XCTAssertTrue(renderer.isCurrent(try XCTUnwrap(successor)))
        XCTAssertEqual(calls.value, 1)
    }
}
#endif
