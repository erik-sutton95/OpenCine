#if canImport(CoreImage) && canImport(CoreVideo) && canImport(Metal)
import CoreImage
import CoreVideo
import Foundation
import OpenCineMedia
import os

/// Off-main assist work. Latest-frame-wins so a slow peaking render cannot stall UDP ingest.
/// Pixel buffers are held as Swift properties  -  ARC retains/releases them. Do not call
/// `CVPixelBufferRetain` / `CVPixelBufferRelease` (unavailable under Swift ARC).
public final class MonitorAssistEngine: @unchecked Sendable {
    public struct Result: @unchecked Sendable {
        public var output: CIImage
        public var identity: CIImage
        public var source: CVPixelBuffer
        public var needsGPU: Bool
        /// Transparent zebra / peaking paint. The identity layer stays the picture.
        public var overlayOnly: Bool
        /// LUT cube product. False for identity fallbacks (NSNull of HEVC is black).
        public var unmanagedBake: Bool
        public var bundle: ScopeAssistBundle?
        public var transfer: MonitorTransfer
        /// False when this result is a late scope bundle. Present already happened.
        public var shouldPresent: Bool
        /// Presentation time for duplicate rejection. `nil` means unknown and is never skipped.
        public var timeNs: Int64?
    }

    private struct Frame: @unchecked Sendable { let buffer: CVPixelBuffer }
    private struct Still: @unchecked Sendable { let image: CGImage }
    private let queue: DispatchQueue
    private let scopeNow: @Sendable () -> CFAbsoluteTime
    private let configuration: MonitorAssistConfiguration
    private let log: Logger
    private let raster = MonitorWorkingRaster()
    private let falseColorMapper: MonitorFalseColorMapper
    private var pendingBuffer: CVPixelBuffer?
    private var pendingEffects = MonitorAssistPolicy()
    private var pendingTransfer = MonitorTransfer.rec709
    private var pendingTimeNs: Int64?
    private var pendingCompletion: (@Sendable (Result) -> Void)?
    /// False for a still a source presents itself: only its scope tap runs.
    private var pendingPresents = true
    private var busy = false
    private var nextScopeAt: CFAbsoluteTime = 0
    /// Rolling tap maximum for the 10 s `scope max:` journal cadence.
    private var ceilingLogMax: UInt8 = 0
    private var nextCeilingLogAt: CFAbsoluteTime = 0
    private var previousBundle = ScopeAssistBundle.empty
    /// The source's ceiling (its bus's, via ``adopt(exposureCeiling:)``). Queue-confined.
    private var exposureCeiling: ScopeExposureCeiling
    private var loggedTap = false
    private var tapWindowStart: CFAbsoluteTime = 0
    private var tapsInWindow = 0
    /// Shared tap: 25 Hz, 10 Hz with three or more scopes, shed further by
    /// thermal tier (×3 serious, ×5 critical). Deadline cannot catch up.

    public convenience init(configuration: MonitorAssistConfiguration = .init()) {
        self.init(configuration: configuration, scopeNow: { CFAbsoluteTimeGetCurrent() })
    }

    /// Keep cadence time and queue readiness controllable without changing the public host API.
    init(configuration: MonitorAssistConfiguration = .init(),
        scopeNow: @escaping @Sendable () -> CFAbsoluteTime,
        queue: DispatchQueue = DispatchQueue(label: "opencine.monitor-assist", qos: .userInitiated)
    ) {
        self.queue = queue
        self.scopeNow = scopeNow
        self.configuration = configuration
        self.log = Logger(subsystem: configuration.logSubsystem, category: "scope-tap")
        self.exposureCeiling = ScopeExposureCeiling(profile: configuration.clipProfile)
        self.falseColorMapper = MonitorFalseColorMapper(lookCurves: configuration.lookCurves)
    }

    /// Measure and ratchet `ceiling` from now on (the bus this engine publishes into).
    public func adopt(exposureCeiling ceiling: OpenCineMedia.ScopeExposureCeiling) {
        queue.async { [self] in exposureCeiling = ceiling }
    }

    public func updatePolicy(effects: MonitorAssistPolicy, transfer: MonitorTransfer) {
        queue.async { [self] in
            var fx = effects
            fx.stamp(transfer: transfer, ceiling: exposureCeiling)
            pendingEffects = fx
            pendingTransfer = transfer
            if fx.image.falseColor {
                falseColorMapper.warm(
                    scale: fx.falseColorScale, transfer: transfer,
                    rec709: fx.falseColorRec709, clipByte: fx.resolvedClipByte,
                    hasLUT: fx.image.lutDimension >= 2)
            }
        }
    }

    public func submit(
        _ buffer: CVPixelBuffer,
        effects: MonitorAssistPolicy? = nil,
        transfer: MonitorTransfer? = nil,
        timeNs: Int64? = nil,
        completion: @escaping @Sendable (Result) -> Void
    ) {
        let frame = Frame(buffer: buffer)
        queue.async { [self] in
            pendingBuffer = raster.prepared(frame.buffer)
            if let effects { pendingEffects = effects }
            if let transfer { pendingTransfer = transfer }
            pendingTimeNs = timeNs
            pendingCompletion = completion
            pendingPresents = true
            drain()
        }
    }

    /// A source that presents its own decoded pictures (motion JPEG) feeds only the scope tap.
    /// A still arriving before the tap is due is dropped unconverted; a due one is copied onto
    /// the working raster on this queue. `completion` receives each sampled bundle.
    public func sample(
        _ image: CGImage, effects: MonitorAssistPolicy, transfer: MonitorTransfer,
        completion: @escaping @Sendable (Result) -> Void
    ) {
        let still = Still(image: image)
        queue.async { [self] in
            guard effects.needsScopes,
                Self.scopeDue(now: scopeNow(), deadline: nextScopeAt,
                    interval: Self.minInterval(activeScopeCount: effects.activeScopeCount)),
                let buffer = raster.prepared(still.image)
            else { return }
            pendingBuffer = buffer
            pendingEffects = effects
            pendingTransfer = transfer
            pendingTimeNs = nil
            pendingCompletion = completion
            pendingPresents = false
            drain()
        }
    }

    public func reset() {
        queue.async { [self] in
            pendingBuffer = nil
            pendingTimeNs = nil
            pendingCompletion = nil
            busy = false
            nextScopeAt = 0
            previousBundle = .empty
            loggedTap = false
            tapWindowStart = 0
            tapsInWindow = 0
            ceilingLogMax = 0
            nextCeilingLogAt = 0
            exposureCeiling.reset()
            raster.reset()
            falseColorMapper.reset()
        }
    }

    private func logTapOnce(
        buffer: CVPixelBuffer,
        packed: (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int)?,
        points: Int
    ) {
        guard !loggedTap else { return }
        loggedTap = true
        let fourCC = LiveFrameTap.fourCC(buffer)
        let srcW = CVPixelBufferGetWidth(buffer)
        let srcH = CVPixelBufferGetHeight(buffer)
        let planes = CVPixelBufferGetPlaneCount(buffer)
        let ioSurface = LiveFrameTap.isIOSurfaceBacked(buffer)
        if let packed {
            let maxLuma = LiveFrameTap.maxRGB(packed.bytes)
            log.info(
                "scope tap \(fourCC, privacy: .public) \(srcW)x\(srcH) planes=\(planes) ioSurface=\(ioSurface) -> \(packed.width)x\(packed.height) max=\(maxLuma) points=\(points)"
            )
            configuration.journal(
                "scope tap format: \(fourCC) \(srcW)x\(srcH) planes=\(planes) -> \(packed.width)x\(packed.height)")
        } else {
            log.error(
                "scope tap FAILED \(fourCC, privacy: .public) \(srcW)x\(srcH) planes=\(planes) ioSurface=\(ioSurface)"
            )
        }
    }

    private func drain() {
        if busy { return }
        guard let buffer = pendingBuffer, let completion = pendingCompletion else { return }
        pendingBuffer = nil
        var fx = pendingEffects
        var transfer = pendingTransfer
        let timeNs = pendingTimeNs
        let presents = pendingPresents
        fx.stamp(transfer: transfer, ceiling: exposureCeiling)
        busy = true
        var imageEffects = fx.image
        if fx.image.falseColor {
            imageEffects.falseColorMaps = falseColorMapper.overlayPairData(
                scale: fx.falseColorScale, transfer: transfer, rec709: fx.falseColorRec709,
                clipByte: fx.resolvedClipByte)?.imageEffectsValue
        }

        // Copy CPU planes before Core Image attaches. WAVE/HISTO read the source
        // buffer; wrapping 10-bit x420 / IOSurface in CIImage first can unmap
        // those planes so the later tap returns nil and scopes stay empty.
        // The histogram walk still runs after present so it cannot hold 25 fps.
        var packed: (bytes: [UInt8], width: Int, height: Int, bytesPerRow: Int)?
        if fx.needsScopes {
            let now = scopeNow()
            let interval = Self.minInterval(activeScopeCount: fx.activeScopeCount)
            if Self.scopeDue(now: now, deadline: nextScopeAt, interval: interval) {
                nextScopeAt = Self.nextScopeDeadline(now: now, deadline: nextScopeAt, interval: interval)
                packed = LiveFrameTap.copyBGRA8(
                    buffer, maxWidth: ScopeSampler.maxWidth)
                if packed == nil {
                    logTapOnce(buffer: buffer, packed: nil, points: 0)
                }
            }
        }

        // Identity keeps Rec.709 / HLG attachments. NSNull is cube-only  -
        // AVSampleBufferDisplayLayer and color-managed CI both go black without them.
        // Scopes-only present uses the pixel buffer, not this image, so skip the wrap.
        let identity: CIImage
        let output: CIImage
        let overlayOnly: Bool
        let unmanagedBake: Bool
        if fx.needsGPUFeed && presents {
            identity = CIImage(cvPixelBuffer: buffer)
            let cameraCodes = CIImage(
                cvPixelBuffer: buffer, options: MonitorWorkingSpace.imageOptions)
            // LUT / false colour cubes read encoded camera codes (WAVE/HISTO buffer).
            // Passing identity here when LUT was off made FALSE sample Rec.709-linearized
            // HEVC, so toggling the cube look moved the painted regions.
            let measure = (fx.image.lutDimension >= 2 || fx.image.falseColor) ? cameraCodes : identity
            if fx.needsOverlayFeed {
                // Measure the same codes WAVE uses; paint only. The picture stays
                // on the identity layer so zebra cannot Rec.709→sRGB the feed.
                output = MonitorImageCompositor.assistOverlay(from: cameraCodes, effects: imageEffects)
                overlayOnly = true
                unmanagedBake = false
            } else {
                let product = MonitorImageCompositor.applyProduct(
                    to: measure, effects: imageEffects, display: identity)
                output = product.image
                overlayOnly = false
                unmanagedBake = product.unmanagedBake
            }
        } else {
            identity = CIImage.empty()
            output = identity
            overlayOnly = false
            unmanagedBake = false
        }

        if presents {
            completion(
                Result(
                    output: output,
                    identity: identity,
                    source: buffer,
                    needsGPU: fx.needsGPUFeed,
                    overlayOnly: overlayOnly,
                    unmanagedBake: unmanagedBake,
                    bundle: nil,
                    transfer: transfer,
                    shouldPresent: true,
                    timeNs: timeNs))
        }

        if let packed {
            let tapMin = LiveFrameTap.minRGB(packed.bytes)
            let tapMax = LiveFrameTap.maxRGB(packed.bytes)
            let inferred = fx.allowsTransferInference
                ? configuration.inferTransfer?(tapMin, tapMax, transfer) ?? transfer
                : transfer
            if inferred != transfer {
                transfer = inferred
                pendingTransfer = inferred
                fx.stamp(transfer: inferred, ceiling: exposureCeiling)
                configuration.journal(
                    "scope transfer: inferred \(inferred.rawValue) min=\(tapMin) max=\(tapMax)"
                )
            }
            var sampled = ScopeSampler.sample(
                bytes: packed.bytes, width: packed.width, height: packed.height,
                bytesPerRow: packed.bytesPerRow, transfer: transfer,
                clipByte: exposureCeiling.clipByte(transfer: transfer),
                includePoints: fx.waveform || fx.parade,
                includeVectorPoints: fx.vectorscope,
                look: fx.vectorscope
                    ? (Self.armedCube(fx.image) ?? configuration.defaultScopeLook(transfer)) : nil,
                trafficThreshold: fx.trafficThreshold,
                previous: previousBundle)
            let observed = exposureCeiling.observeTapMax(tapMax, transfer: transfer)
            // Views draw this bundle on the ceiling now in force (after this tap's ratchet).
            sampled.clipByte = Int(observed.clip)
            previousBundle = sampled
            logTapOnce(buffer: buffer, packed: packed, points: sampled.samples.points.count)
            let tapNow = CFAbsoluteTimeGetCurrent()
            let interval = Self.minInterval(activeScopeCount: fx.activeScopeCount)
            tapsInWindow += 1
            if tapWindowStart == 0 { tapWindowStart = tapNow }
            let elapsed = tapNow - tapWindowStart
            if elapsed >= 2 {
                let hz = Double(tapsInWindow) / elapsed
                let budget = 1.0 / interval
                configuration.journal(
                    String(
                        format: "scope tap: %.1fHz budget=%.0fHz scopes=%d", hz, budget,
                        fx.activeScopeCount))
                tapsInWindow = 0
                tapWindowStart = tapNow
            }
            // Ceiling calibration breadcrumb: rolling 10 s tap maximum
            // into the pullable journal (tools/pull-control-log.sh).
            // Point the lens at a blown lamp at each ISO and read the
            // saturation byte straight off these lines.
            ceilingLogMax = max(ceilingLogMax, tapMax)
            let now = CFAbsoluteTimeGetCurrent()
            if now >= nextCeilingLogAt {
                nextCeilingLogAt = now + 10
                configuration.journal(
                    "scope max: byte=\(ceilingLogMax) clip=\(observed.clip) transfer=\(transfer.rawValue) ei=\(exposureCeiling.resolvedISO().map(String.init) ?? "unknown")"
                )
                ceilingLogMax = 0
            }
            completion(
                Result(
                    output: output,
                    identity: identity,
                    source: buffer,
                    needsGPU: false,
                    overlayOnly: false,
                    unmanagedBake: false,
                    bundle: sampled,
                    transfer: transfer,
                        shouldPresent: false,
                    timeNs: timeNs))
        }

        queue.async { [self] in
            busy = false
            drain()
        }
    }

    /// A frame that lands a little early for its tap still takes it. Frames arrive at the clip
    /// rate with scheduling jitter, so a deadline of exactly one interval after the previous tap
    /// skipped every other frame: a 25 fps clip measured at 12 to 15 Hz instead of its 25 Hz.
    static func scopeDue(now: CFAbsoluteTime, deadline: CFAbsoluteTime, interval: TimeInterval)
        -> Bool
    {
        now >= deadline - interval * 0.25
    }

    /// The deadline advances one interval per tap, so the rate never exceeds the budget. A tap
    /// so late that the next deadline's early window is already open restarts from now instead
    /// of catching up, so two taps are never one source frame apart.
    static func nextScopeDeadline(
        now: CFAbsoluteTime, deadline: CFAbsoluteTime, interval: TimeInterval
    ) -> CFAbsoluteTime {
        let next = deadline + interval
        return scopeDue(now: now, deadline: next, interval: interval) ? now + interval : next
    }

    public static func minInterval(activeScopeCount: Int,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState) -> TimeInterval {
        let base = activeScopeCount > ScopeSampler.denseAssistThreshold
            ? ScopeSampler.denseMinInterval : ScopeSampler.baseMinInterval
        return base * thermalMultiplier(thermalState)
    }
    public static func thermalMultiplier(_ state: ProcessInfo.ThermalState) -> Double {
        switch state { case .serious: 3; case .critical: 5; default: 1 }
    }
    public static func armedCube(_ effects: MonitorImageEffects) -> CubeLUT? {
        let n = effects.lutDimension
        guard n >= 2, n <= CubeLUT.supportedSizeRange.upperBound,
            effects.lutRGBA.count == n * n * n * 4 * MemoryLayout<Float>.size else { return nil }
        let floats = effects.lutRGBA.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var rgb = [Float](); rgb.reserveCapacity(n * n * n * 3)
        for index in stride(from: 0, to: floats.count, by: 4) {
            rgb.append(contentsOf: floats[index..<index + 3])
        }
        return CubeLUT(size: n, rgb: rgb)
    }
}
#endif
