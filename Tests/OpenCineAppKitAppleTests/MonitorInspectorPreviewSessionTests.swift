#if os(iOS)
import CoreVideo
import Foundation
import Observation
import OpenCineApple
import OpenCineMedia
import UIKit
import XCTest
@testable import OpenCineAppKitApple

/// SIMULATED pixels; the real retained renderer runs on a manual admission clock.
@MainActor final class MonitorInspectorPreviewSessionTests: XCTestCase {
    func testCurrentOwnerReceivesPicture() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.session.synchronize(currentMeaning: { "current" }) { _ in MonitorFrameEffects() }
        let owner = fixture.session.activate(source: fixture.source)
        await fixture.session.pulse(owner: owner)
        XCTAssertEqual(fixture.session.image(matching: "current")?.width, 1)
        XCTAssertNil(fixture.session.image(matching: "successor"))
        XCTAssertEqual(fixture.probe.operationCount, 1)
    }

    func testMissingMeaningDoesNotRender() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.session.synchronize(currentMeaning: { nil }) { _ in
            XCTFail("Absent image meaning must not prepare a look")
            return MonitorFrameEffects()
        }
        let owner = fixture.session.activate(source: fixture.source)
        await fixture.session.pulse(owner: owner)
        XCTAssertNil(fixture.session.image)
        XCTAssertEqual(fixture.probe.operationCount, 0)
        XCTAssertEqual(fixture.probe.clockReadCount, 0)
    }

    func testRetiredOwnerCannotPublish() async throws {
        let fixture = try Fixture(blockFirst: true)
        defer { fixture.close() }
        fixture.session.synchronize(currentMeaning: { "current" }) { _ in MonitorFrameEffects() }
        let owner = fixture.session.activate(source: fixture.source)
        let pending = Task { await fixture.session.pulse(owner: owner) }
        let entered = await XCTWaiter.fulfillment(of: [fixture.probe.entered], timeout: 5)
        XCTAssertEqual(entered, .completed)
        fixture.session.deactivate(owner: owner)
        fixture.probe.release()
        await pending.value
        XCTAssertFalse(fixture.session.isCurrent(owner))
        XCTAssertNil(fixture.session.image)
        XCTAssertEqual(fixture.probe.operationCount, 1)
    }

    func testOldOwnerCannotCloseSuccessor() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.session.synchronize(currentMeaning: { "current" }) { _ in MonitorFrameEffects() }
        let old = fixture.session.activate(source: fixture.source)
        let successor = fixture.session.activate(source: fixture.source)
        fixture.session.deactivate(owner: old)
        XCTAssertTrue(fixture.session.isCurrent(successor))
        await fixture.session.pulse(owner: successor)
        XCTAssertEqual(fixture.session.image?.width, 1)
    }

    func testReplacementDuringPreparationPreservesSuccessor() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let successor = OwnerBox()
        fixture.session.synchronize(currentMeaning: { "old" }) { _ in
            fixture.session.synchronize(currentMeaning: { "new" }) { _ in MonitorFrameEffects() }
            successor.owner = fixture.session.activate(source: fixture.source)
            return MonitorFrameEffects()
        }
        let old = fixture.session.activate(source: fixture.source)
        await fixture.session.pulse(owner: old)
        let current = try XCTUnwrap(successor.owner)
        XCTAssertFalse(fixture.session.isCurrent(old))
        XCTAssertTrue(fixture.session.isCurrent(current))
        XCTAssertNil(fixture.session.image)
        fixture.session.deactivate(owner: old)
        fixture.probe.advance()
        await fixture.session.pulse(owner: current)
        XCTAssertEqual(fixture.session.image(matching: "new")?.width, 1)
    }

    func testReplacementDuringPicturePublicationPreservesSuccessor() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.session.synchronize(currentMeaning: { "old" }) { _ in MonitorFrameEffects() }
        let old = fixture.session.activate(source: fixture.source)
        let successor = OwnerBox()
        withObservationTracking {
            _ = fixture.session.image
        } onChange: {
            MainActor.assumeIsolated {
                fixture.session.synchronize(currentMeaning: { "new" }) { _ in MonitorFrameEffects() }
                successor.owner = fixture.session.activate(source: fixture.source)
            }
        }
        await fixture.session.pulse(owner: old)
        let current = try XCTUnwrap(successor.owner)
        XCTAssertTrue(fixture.session.isCurrent(current))
        XCTAssertNil(fixture.session.image, "Old publication cannot refill the successor")
        fixture.session.deactivate(owner: old)
        fixture.probe.advance()
        await fixture.session.pulse(owner: current)
        XCTAssertEqual(fixture.session.image(matching: "new")?.width, 1)
    }

    func testMeaningChangeRetainsOccupiedNativeSlot() async throws {
        let fixture = try Fixture(blockFirst: true)
        defer { fixture.close() }
        fixture.session.synchronize(currentMeaning: { "old" }) { _ in MonitorFrameEffects() }
        let owner = fixture.session.activate(source: fixture.source)
        let pending = Task { await fixture.session.pulse(owner: owner) }
        let entered = await XCTWaiter.fulfillment(of: [fixture.probe.entered], timeout: 5)
        XCTAssertEqual(entered, .completed)
        fixture.session.synchronize(currentMeaning: { "new" }) { _ in MonitorFrameEffects() }
        fixture.probe.advance()
        await fixture.session.pulse(owner: owner)
        XCTAssertEqual(fixture.probe.operationCount, 1, "Meaning changes cannot release running work")
        fixture.probe.release()
        await pending.value
        XCTAssertNil(fixture.session.image)
        await fixture.session.pulse(owner: owner)
        XCTAssertEqual(fixture.probe.operationCount, 2)
        XCTAssertEqual(fixture.session.image(matching: "new")?.width, 1)
    }

    func testSourceRetirementRefusesOldCompletion() async throws {
        let fixture = try Fixture(blockFirst: true)
        defer { fixture.close() }
        fixture.session.synchronize(currentMeaning: { "current" }) { _ in MonitorFrameEffects() }
        let owner = fixture.session.activate(source: fixture.source)
        let pending = Task { await fixture.session.pulse(owner: owner) }
        let entered = await XCTWaiter.fulfillment(of: [fixture.probe.entered], timeout: 5)
        XCTAssertEqual(entered, .completed)
        fixture.replaceSource()
        fixture.probe.release()
        await pending.value
        XCTAssertNil(fixture.session.image)
        fixture.probe.advance()
        await fixture.session.pulse(owner: owner)
        XCTAssertEqual(fixture.session.image?.width, 1)
    }

    func testUpdateUsesLatestPreparationWithoutInventingMeaning() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        var oldPreparations = 0
        var currentPreparations = 0
        fixture.session.synchronize(currentMeaning: { "current" }) { _ in
            oldPreparations += 1
            return MonitorFrameEffects()
        }
        let owner = fixture.session.activate(source: fixture.source)
        fixture.session.synchronize(currentMeaning: { "current" }) { _ in
            currentPreparations += 1
            return MonitorFrameEffects()
        }
        await fixture.session.pulse(owner: owner)
        XCTAssertEqual(oldPreparations, 0)
        XCTAssertEqual(currentPreparations, 1)
        XCTAssertEqual(fixture.session.image?.width, 1)
    }

    func testChangedMeaningBeforeViewUpdateRefusesOldCompletion() async throws {
        let fixture = try Fixture(blockFirst: true)
        defer { fixture.close() }
        let current = MeaningBox()
        fixture.session.synchronize(currentMeaning: { current.value }) { _ in MonitorFrameEffects() }
        let owner = fixture.session.activate(source: fixture.source)
        let pending = Task { await fixture.session.pulse(owner: owner) }
        let entered = await XCTWaiter.fulfillment(of: [fixture.probe.entered], timeout: 5)
        XCTAssertEqual(entered, .completed)
        current.value = "changed"
        fixture.probe.release()
        await pending.value
        XCTAssertNil(fixture.session.image, "Read current meaning after native completion, before view synchronization")
        fixture.session.synchronize(currentMeaning: { current.value }) { _ in MonitorFrameEffects() }
        fixture.probe.advance()
        await fixture.session.pulse(owner: owner)
        XCTAssertEqual(fixture.session.image(matching: "changed")?.width, 1)
    }

    func testMeaningReadReentryCannotStartOldNativeWork() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let current = MeaningBox()
        fixture.session.synchronize(currentMeaning: {
            current.reads += 1
            if current.reads == 2 {
                fixture.session.synchronize(currentMeaning: { "new" }) { _ in MonitorFrameEffects() }
                current.successor = fixture.session.activate(source: fixture.source)
            }
            return current.value
        }) { _ in MonitorFrameEffects() }
        let old = fixture.session.activate(source: fixture.source)
        await fixture.session.pulse(owner: old)
        let successor = try XCTUnwrap(current.successor)
        XCTAssertTrue(fixture.session.isCurrent(successor))
        XCTAssertEqual(fixture.probe.operationCount, 0)
        XCTAssertEqual(fixture.probe.clockReadCount, 0)
        await fixture.session.pulse(owner: successor)
        XCTAssertEqual(fixture.session.image(matching: "new")?.width, 1)
    }

    func testPostRenderMeaningReadReentryCannotPublishOldPicture() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let current = MeaningBox()
        fixture.session.synchronize(currentMeaning: {
            current.reads += 1
            if current.reads == 3 {
                fixture.session.synchronize(currentMeaning: { "new" }) { _ in MonitorFrameEffects() }
                current.successor = fixture.session.activate(source: fixture.source)
            }
            return current.value
        }) { _ in MonitorFrameEffects() }
        let old = fixture.session.activate(source: fixture.source)
        await fixture.session.pulse(owner: old)
        let successor = try XCTUnwrap(current.successor)
        XCTAssertTrue(fixture.session.isCurrent(successor))
        XCTAssertNil(fixture.session.image)
        XCTAssertEqual(fixture.probe.operationCount, 1)
        fixture.probe.advance()
        await fixture.session.pulse(owner: successor)
        XCTAssertEqual(fixture.session.image(matching: "new")?.width, 1)
    }

    func testFirstRealFrameCanRenderBeforeViewUpdate() async throws {
        let fixture = try Fixture(publishFirst: false)
        defer { fixture.close() }
        fixture.session.synchronize(currentMeaning: {
            fixture.source.snapshot == nil ? nil : "first"
        }) { _ in MonitorFrameEffects() }
        let owner = fixture.session.activate(source: fixture.source)
        await fixture.session.pulse(owner: owner)
        XCTAssertNil(fixture.session.image)
        XCTAssertEqual(fixture.probe.operationCount, 0)
        fixture.publish()
        await fixture.session.pulse(owner: owner)
        XCTAssertEqual(fixture.session.image(matching: "first")?.width, 1)
        XCTAssertEqual(fixture.probe.operationCount, 1)
    }

    func testDeactivationReleasesUnmountedViewInputCapture() {
        weak var released: MonitorInspectorPreviewSession<String>?
        autoreleasepool {
            let session = MonitorInspectorPreviewSession<String>()
            released = session
            session.synchronize(currentMeaning: { [session] in
                _ = session.image
                return nil
            }) { _ in MonitorFrameEffects() }
            session.deactivate()
        }
        XCTAssertNil(released, "Unmount must release even a source-less view's retained input closure")
    }
}

@MainActor private final class OwnerBox { var owner: UUID? }
@MainActor private final class MeaningBox {
    var value = "current"
    var reads = 0
    var successor: UUID?
}

@MainActor private final class Fixture {
    let session = MonitorInspectorPreviewSession<String>()
    let samples = LiveFrameSampleBus()
    let probe: RenderProbe
    let source: MonitorInspectorImageSource
    private let buffer: CVPixelBuffer
    private var lease: LiveFrameSampleBus.Source

    init(blockFirst: Bool = false, publishFirst: Bool = true) throws {
        probe = RenderProbe(blockFirst: blockFirst)
        let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: try XCTUnwrap(CGDataProvider(data: Data([255, 255, 255, 255]) as CFData)),
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let captured = probe
        // The test blocks this worker and awaits it from the main actor: same tier as the waiter.
        let renderer = MonitorInspectorImageRenderer(lookCurves: [:], now: { captured.now },
            operation: { _, _ in captured.render(); return image }, workerQoS: .userInitiated)
        source = MonitorInspectorImageSource(renderer: renderer, samples: samples)
        var allocated: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &allocated)
        XCTAssertEqual(result, kCVReturnSuccess)
        buffer = try XCTUnwrap(allocated)
        lease = samples.openSource(.live)
        if publishFirst { publish() }
    }
    func publish() {
        samples.publish(lease, source: buffer, transfer: .rec709, reportedTransfer: .rec709, bundle: nil)
    }
    func replaceSource() { lease = samples.openSource(.live); publish() }
    func close() { probe.release(); session.deactivate(); samples.closeSource(lease) }
}

private final class RenderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let blockFirst: Bool
    private var time: UInt64 = 1_000_000_000
    private var renders = 0
    private var reads = 0
    let entered = XCTestExpectation(description: "SIMULATED native worker entered")
    init(blockFirst: Bool) { self.blockFirst = blockFirst }
    var now: UInt64 { lock.withLock { reads += 1; return time } }
    var operationCount: Int { lock.withLock { renders } }
    var clockReadCount: Int { lock.withLock { reads } }
    func advance() { lock.withLock { time += MonitorPreviewAdmission.minimumIntervalNanoseconds } }
    func release() { gate.signal() }
    func render() {
        let count = lock.withLock { renders += 1; return renders }
        if blockFirst && count == 1 {
            entered.fulfill()
            XCTAssertEqual(gate.wait(timeout: .now() + 5), .success, "Controlled render was not released")
        }
    }
}
#endif
