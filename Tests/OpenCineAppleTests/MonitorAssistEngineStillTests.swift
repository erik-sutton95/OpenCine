#if canImport(CoreImage) && canImport(CoreVideo) && canImport(Metal)
import CoreGraphics
import CoreVideo
import Foundation
import OpenCineMedia
import Testing
import XCTest

@testable import OpenCineApple

private final class StillScopeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CFAbsoluteTime = 100
    var now: CFAbsoluteTime { lock.withLock { value } }
    func set(_ value: CFAbsoluteTime) { lock.withLock { self.value = value } }
}

/// A source that presents its own decoded stills (motion JPEG) runs the same scope tap, lamps
/// and ceiling as a video source. SIMULATED frames.
@Suite struct MonitorAssistEngineStillTests {
    private static let width = 160
    private static let height = 90

    private static func rgba() -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8((x * 3) % 256)
                bytes[i + 1] = UInt8((x + y * 2) % 256)
                bytes[i + 2] = x < 40 ? 200 : UInt8((y * 5) % 256)
            }
        }
        return bytes
    }

    private static func image(_ rgba: [UInt8]) throws -> CGImage {
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        return try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent))
    }

    private static func buffer(_ rgba: [UInt8]) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &created)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let o = y * rowBytes + x * 4
                (base[o], base[o + 1], base[o + 2], base[o + 3]) =
                    (rgba[i + 2], rgba[i + 1], rgba[i], 255)
            }
        }
        return buffer
    }

    @Test func aStillGetsTheVideoTapsBundleOnTheDeclaredCeiling() async throws {
        let rgba = Self.rgba()
        let ceiling = ScopeExposureCeiling()
        ceiling.declare(clipByte: 180, for: .log3G10)
        let engine = MonitorAssistEngine()
        engine.adopt(exposureCeiling: ceiling)
        var policy = MonitorAssistPolicy()
        policy.waveform = true
        policy.trafficLights = true
        policy.trafficThreshold = 0.05
        let results = AsyncStream<MonitorAssistEngine.Result>.makeStream()
        engine.sample(try Self.image(rgba), effects: policy, transfer: .log3G10) {
            results.continuation.yield($0)
        }
        var iterator = results.stream.makeAsyncIterator()
        let result = try #require(await iterator.next())
        #expect(
            !result.shouldPresent, "a still is presented by its source, never by the engine")
        let bundle = try #require(result.bundle)

        let tap = try #require(
            LiveFrameTap.copyBGRA8(try Self.buffer(rgba), maxWidth: ScopeSampler.maxWidth))
        let expected = ScopeSampler.sample(
            bytes: tap.bytes, width: tap.width, height: tap.height,
            bytesPerRow: tap.bytesPerRow, transfer: .log3G10, clipByte: 180,
            includePoints: true, look: nil,
            trafficThreshold: 0.05, previous: .empty)
        #expect(bundle == expected)
        #expect(bundle.transfer == .log3G10 && bundle.clipByte == 180)

        // The bundle from already-walked samples is the same derivation.
        let raw = ScopeSampler.sampleRaw(
            bytes: tap.bytes, width: tap.width, height: tap.height,
            bytesPerRow: tap.bytesPerRow, transfer: .log3G10, includePoints: true)
        #expect(
            ScopeSampler.bundle(
                samples: raw, transfer: .log3G10, clipByte: 180, includePoints: true, look: nil,
                trafficThreshold: 0.05, previous: .empty) == expected)
    }

    /// A 2-point cube in red-fastest order, from a per-corner colour map.
    private static func cube(_ map: (Float, Float, Float) -> (Float, Float, Float)) -> CubeLUT {
        var rgb = [Float]()
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 {
            let out = map(Float(r), Float(g), Float(b))
            rgb.append(contentsOf: [out.0, out.1, out.2])
        } } }
        return CubeLUT(size: 2, rgb: rgb)
    }

    private static func allScopes() -> MonitorAssistPolicy {
        var policy = MonitorAssistPolicy()
        policy.histogram = true
        policy.waveform = true
        policy.parade = true
        policy.vectorscope = true
        policy.trafficLights = true
        return policy
    }

    private static func firstBundle(
        _ policy: MonitorAssistPolicy, configuration: MonitorAssistConfiguration,
        still: Bool
    ) async throws -> ScopeAssistBundle {
        let engine = MonitorAssistEngine(configuration: configuration)
        let results = AsyncStream<MonitorAssistEngine.Result>.makeStream()
        let receive: @Sendable (MonitorAssistEngine.Result) -> Void = {
            if $0.bundle != nil { results.continuation.yield($0) }
        }
        if still {
            engine.sample(try image(rgba()), effects: policy, transfer: .log3G10, completion: receive)
        } else {
            engine.submit(try buffer(rgba()), effects: policy, transfer: .log3G10, completion: receive)
        }
        var iterator = results.stream.makeAsyncIterator()
        let result = try #require(await iterator.next())
        return try #require(result.bundle)
    }

    /// The scopes measure the camera signal, not the monitoring look: arming a LUT (here one
    /// that inverts every colour) leaves waveform, parade, histogram, traffic lights and VECTOR
    /// exactly as they were, on a still source and on a video source alike. VECTOR still reads
    /// the source's fixed display transform.
    @Test(arguments: [true, false])
    func togglingTheMonitoringLUTLeavesEveryScopeUnchanged(still: Bool) async throws {
        let display = Self.cube { r, g, b in (b, g, r) }
        let configuration = MonitorAssistConfiguration(
            defaultScopeLook: { $0 == .log3G10 ? display : nil })
        let lutOff = Self.allScopes()
        var lutOn = lutOff
        let inverting = Self.cube { r, g, b in (1 - r, 1 - g, 1 - b) }
        lutOn.image.lutDimension = inverting.size
        lutOn.image.lutRGBA = inverting.rgbaComponents.withUnsafeBytes { Data($0) }

        let off = try await Self.firstBundle(lutOff, configuration: configuration, still: still)
        let on = try await Self.firstBundle(lutOn, configuration: configuration, still: still)

        #expect(on == off, "a monitoring LUT never reaches the scope bundle")
        #expect(!off.samples.points.isEmpty && !off.vectorscopePoints.isEmpty)
        #expect(
            off.vectorscopePoints == ScopeSampler.monitorPoints(off.samples.points, look: display),
            "VECTOR reads the source's display transform of the clean samples")
    }

    // Native preparation is fixture setup, not a cold-start latency contract. Each cadence
    // scenario starts after the real per-owner conversion and a queued reset have completed.
    private static func prepareNativeStill(
        _ engine: MonitorAssistEngine, image: CGImage, effects: MonitorAssistPolicy,
        on queue: DispatchQueue
    ) async throws {
        let ready = XCTestExpectation(description: "native still fixture prepared")
        let first = AsyncStream<MonitorAssistEngine.Result>.makeStream()
        engine.sample(image, effects: effects, transfer: .rec709) {
            first.continuation.yield($0)
            first.continuation.finish()
            ready.fulfill()
        }
        let preparation = await XCTWaiter.fulfillment(of: [ready], timeout: 5.0)
        try #require(preparation == .completed, "real native fixture preparation has a separate 5 s bound")
        var iterator = first.stream.makeAsyncIterator()
        let result = try #require(await iterator.next())
        try #require(result.bundle != nil, "fixture preparation must process a real native still")
        engine.reset()
        try await finishPendingWork(on: queue)
    }

    private static func finishPendingWork(on queue: DispatchQueue) async throws {
        let finished = XCTestExpectation(description: "still samples and deferred drain finished")
        // drain schedules one more pass after the submitted sample blocks.
        queue.async { queue.async { finished.fulfill() } }
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 0.3)
        try #require(result == .completed, "retain the original 300 ms readiness budget")
    }

    @Test func aStillBeforeTheTapIsDueIsDropped() async throws {
        let clock = StillScopeClock()
        let queue = DispatchQueue(label: "opencine.test.still-before-due")
        let engine = MonitorAssistEngine(scopeNow: { clock.now }, queue: queue)
        var policy = MonitorAssistPolicy()
        // Three scopes share the dense (slowest) cadence.
        policy.histogram = true
        policy.waveform = true
        policy.parade = true
        let image = try Self.image(Self.rgba())
        try await Self.prepareNativeStill(engine, image: image, effects: policy, on: queue)
        let results = AsyncStream<MonitorAssistEngine.Result>.makeStream()
        // Keep the first scenario sample pending until all original submissions are queued.
        queue.suspend()
        for _ in 0..<3 {
            engine.sample(image, effects: policy, transfer: .rec709) {
                results.continuation.yield($0)
            }
        }
        // A scope-free policy never converts or taps.
        engine.sample(image, effects: MonitorAssistPolicy(), transfer: .rec709) {
            results.continuation.yield($0)
        }
        queue.resume()
        // Frozen cadence time establishes that all three admissions are pre-due,
        // even when native work or scheduling takes longer than a real interval.
        try await Self.finishPendingWork(on: queue)
        results.continuation.finish()
        var count = 0
        for await result in results.stream {
            #expect(result.bundle != nil)
            count += 1
        }
        #expect(count == 1, "one tap per interval; later stills before it are dropped")
    }

    @Test func theNextDueStillIsAcceptedAfterAnEarlyStillIsDropped() async throws {
        let clock = StillScopeClock()
        let queue = DispatchQueue(label: "opencine.test.still-next-due")
        let engine = MonitorAssistEngine(scopeNow: { clock.now }, queue: queue)
        var policy = MonitorAssistPolicy()
        policy.histogram = true
        policy.waveform = true
        policy.parade = true
        let image = try Self.image(Self.rgba())
        try await Self.prepareNativeStill(engine, image: image, effects: policy, on: queue)
        let interval = MonitorAssistEngine.minInterval(activeScopeCount: policy.activeScopeCount)
        let results = AsyncStream<MonitorAssistEngine.Result>.makeStream()
        let receive: @Sendable (MonitorAssistEngine.Result) -> Void = {
            results.continuation.yield($0)
        }
        engine.sample(image, effects: policy, transfer: .rec709, completion: receive)
        try await Self.finishPendingWork(on: queue)

        clock.set(100 + interval - 0.001)
        engine.sample(image, effects: policy, transfer: .rec709, completion: receive)
        try await Self.finishPendingWork(on: queue)

        clock.set(100 + interval)
        // A scope-free still cannot consume the due tap before the scoped control.
        engine.sample(image, effects: MonitorAssistPolicy(), transfer: .rec709, completion: receive)
        engine.sample(image, effects: policy, transfer: .rec709, completion: receive)
        try await Self.finishPendingWork(on: queue)
        results.continuation.finish()
        var count = 0
        for await result in results.stream {
            #expect(result.bundle != nil)
            #expect(!result.shouldPresent)
            count += 1
        }
        #expect(count == 2, "the early still is dropped and the next due still is sampled")
    }
}
#endif
