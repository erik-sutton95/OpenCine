#if os(iOS)
import CoreGraphics
import CoreVideo
import Dispatch
import Foundation
import OpenCineMedia
import XCTest
@testable import OpenCineApple

/// SIMULATED pixels. Hosted CI showed the utility worker entering 6 s after admission while
/// the main thread and the waiting test ran within milliseconds (2026-10-23, OpenPocketCine
/// scratch run 40017274840); past the 10 s event budget the app tests failed. Production keeps
/// utility. A test that blocks the worker and awaits its events passes the waiter's tier.
@MainActor final class MonitorInspectorImageRendererSchedulingTests: XCTestCase {
    func testProductionWorkerYieldsAtUtilityQoS() async throws {
        XCTAssertEqual(MonitorInspectorImageRenderer.defaultWorkerQoS, .utility)
        let observed = try await workerQoS(of: MonitorInspectorImageRenderer(
            lookCurves: [:], operation: Self.recordingOperation))
        XCTAssertEqual(observed, QOS_CLASS_UTILITY,
            "The inspector preview must not compete with the live picture")
    }

    func testHostedTestWorkerRunsAtTheInjectedTier() async throws {
        let observed = try await workerQoS(of: MonitorInspectorImageRenderer(
            lookCurves: [:], operation: Self.recordingOperation, workerQoS: .userInitiated))
        XCTAssertEqual(observed, QOS_CLASS_USER_INITIATED,
            "A test that awaits worker events from the main thread must not wait on a lower tier")
    }

    nonisolated private static let observedQoS = QoSRecord()

    nonisolated private static let recordingOperation: MonitorInspectorImageRenderer.RenderOperation = { _, _ in
        observedQoS.set(qos_class_self())
        return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data([255, 255, 255, 255]) as CFData)!,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func workerQoS(of renderer: MonitorInspectorImageRenderer) async throws -> qos_class_t? {
        Self.observedQoS.set(nil)
        var allocated: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &allocated), kCVReturnSuccess)
        let buffer = try XCTUnwrap(allocated)
        let owner = UUID()
        renderer.activate(owner: owner)
        // Submitted from the main actor: the worker must keep the queue's tier, not the caller's.
        let result = await renderer.render(owner: owner, source: buffer) { MonitorFrameEffects() }
        XCTAssertNotNil(result)
        return Self.observedQoS.get()
    }
}

private final class QoSRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var value: qos_class_t?
    func set(_ next: qos_class_t?) { lock.withLock { value = next } }
    func get() -> qos_class_t? { lock.withLock { value } }
}
#endif
