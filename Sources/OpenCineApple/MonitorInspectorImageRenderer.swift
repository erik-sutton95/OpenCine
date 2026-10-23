#if os(iOS)
import CoreImage
import CoreVideo
import Foundation
import OpenCineMedia

/// Inspector-only image work: at most one admitted source buffer, no pending
/// queue, and no display/decoder attachment. A busy job drops a request; the
/// view's next bounded tick reads the newest source instead of catching up.
public final class MonitorInspectorImageRenderer: @unchecked Sendable {
    public typealias RenderOperation = @Sendable (CVPixelBuffer, MonitorFrameEffects) -> CGImage?
    public typealias Clock = @Sendable () -> UInt64

    public struct Result: Sendable {
        public let image: CGImage
        fileprivate let ticket: MonitorPreviewAdmission.Ticket
        fileprivate let source: LiveFrameSampleBus.InspectorFrame?
    }

    public let falseColorMapper: MonitorFalseColorMapper
    /// Inspector previews yield to the live picture: production work runs at utility QoS.
    public static let defaultWorkerQoS: DispatchQoS = .utility
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var admission = MonitorPreviewAdmission()
    private let now: Clock
    private let operation: RenderOperation?
    // These contexts are used only on queue, never by the live present worker.
    private var displayContext: CIContext?
    private var cubeContext: CIContext?

    /// `workerQoS` is a scheduling choice only; admission and ownership never depend on it.
    /// Hosted tests that block a worker and await its events from the main thread pass the
    /// waiter's tier: at utility, a loaded simulator can delay worker entry past any event budget.
    public init(lookCurves: [MonitorTransfer: [Double]],
        now: @escaping Clock = { DispatchTime.now().uptimeNanoseconds },
        operation: RenderOperation? = nil,
        workerQoS: DispatchQoS = MonitorInspectorImageRenderer.defaultWorkerQoS
    ) {
        queue = DispatchQueue(label: "opencine.assist-inspector", qos: workerQoS)
        falseColorMapper = MonitorFalseColorMapper(lookCurves: lookCurves)
        self.now = now
        self.operation = operation
    }

    public func activate(owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        admission.activate(owner: owner)
    }

    public func invalidate(owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        admission.invalidate(owner: owner)
    }

    public func deactivate(owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        admission.deactivate(owner: owner)
    }

    @MainActor public func isCurrent(_ result: Result) -> Bool {
        isCurrent(result.ticket) && (result.source?.isCurrent ?? true)
    }

    @MainActor
    public func render(owner: UUID, source: LiveFrameSampleBus.InspectorFrame,
        effects: @MainActor () -> MonitorFrameEffects) async -> Result? {
        await render(owner: owner, buffer: source.buffer, source: source, effects: effects)
    }

    /// Admission remains occupied through native work and main-actor delivery.
    /// Cancelling an owner invalidates adoption but cannot free running CI work.
    @MainActor
    public func render(
        owner: UUID, source: CVPixelBuffer, effects: @MainActor () -> MonitorFrameEffects
    ) async -> Result? {
        await render(owner: owner, buffer: source, source: nil, effects: effects)
    }

    @MainActor
    private func render(owner: UUID, buffer: CVPixelBuffer, source: LiveFrameSampleBus.InspectorFrame?,
        effects: @MainActor () -> MonitorFrameEffects) async -> Result? {
        guard !Task.isCancelled, source?.isCurrent ?? true,
            let ticket = reserve(owner: owner) else { return nil }
        defer { complete(ticket) }
        // LUT preview preparation belongs to the same admission as image work.
        // Rejected tab/option changes must not repeatedly build a color cube.
        let effects = effects()
        let work = InspectorImageWork()
        let retainedBuffer = InspectorImageBuffer(value: buffer)
        let image: CGImage? = await withTaskCancellationHandler {
            return await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let image: CGImage?
                    if work.isCancelled || !isCurrent(ticket) || !(source?.lease.isActive ?? true) {
                        image = nil
                    } else if let operation {
                        image = operation(retainedBuffer.value, effects)
                    } else {
                        image = renderImage(source: retainedBuffer.value, effects: effects)
                    }
                    continuation.resume(returning: work.isCancelled ? nil : image)
                }
            }
        } onCancel: {
            work.cancel()
            self.deactivate(owner: owner)
        }
        guard !Task.isCancelled, isCurrent(ticket), source?.isCurrent ?? true, let image else { return nil }
        return Result(image: image, ticket: ticket, source: source)
    }

    private func reserve(owner: UUID) -> MonitorPreviewAdmission.Ticket? {
        lock.lock()
        defer { lock.unlock() }
        return admission.acquire(owner: owner, nowNanoseconds: now())
    }

    private func isCurrent(_ ticket: MonitorPreviewAdmission.Ticket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return admission.isCurrent(ticket)
    }

    private func complete(_ ticket: MonitorPreviewAdmission.Ticket) {
        lock.lock()
        defer { lock.unlock() }
        admission.complete(ticket)
    }

    /// A caller with its own retained instance may reuse the production display
    /// look on a serial worker. It must not overlap this with `render` on that instance.
    public func renderImage(source: CVPixelBuffer, effects: MonitorFrameEffects) -> CGImage? {
        autoreleasepool {
            guard let look = lookImage(source: source, effects: effects) else { return nil }
            return look.context.createCGImage(look.image, from: look.image.extent)
        }
    }

    /// The display look at most 320 px on its longest side, at the origin, and
    /// the context whose output encoding `renderImage` would produce. A caller
    /// may render it elsewhere with that context (and `outputColorSpace`) and get
    /// the same pixels without a CPU readback.
    public func lookImage(source: CVPixelBuffer, effects: MonitorFrameEffects)
        -> (image: CIImage, context: CIContext, outputColorSpace: CGColorSpace?)?
    {
        let width = CGFloat(CVPixelBufferGetWidth(source))
        let height = CGFloat(CVPixelBufferGetHeight(source))
        guard width > 0, height > 0 else { return nil }
        let scale = min(
            1, MonitorInspectorImageSizing.maximumDimension / max(width, height))
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        // Downscale before every compositor graph. Preserve native source
        // codes for the tool and source attachments for its identity look.
        let identity = CIImage(cvPixelBuffer: source).transformed(by: transform)
        let codes = CIImage(
            cvPixelBuffer: source, options: MonitorWorkingSpace.imageOptions
        )
        .transformed(by: transform)
        if effects.falseColor {
            falseColorMapper.warm(
                scale: effects.falseColorScale.liveScale, transfer: effects.transfer,
                rec709: effects.falseColorRec709, clipByte: effects.resolvedClipByte,
                hasLUT: effects.lutDimension >= 2)
        }
        let product = MonitorImageCompositor.applyProduct(
            to: codes, effects: effects.nativeImageEffects(using: falseColorMapper), display: identity)
        var result = product.image
        let outputScale = min(
            1,
            MonitorInspectorImageSizing.maximumDimension
                / max(result.extent.width, result.extent.height))
        if outputScale < 1 {
            result = result.transformed(
                by: CGAffineTransform(scaleX: outputScale, y: outputScale))
        }
        if effects.mirror || effects.mirrorVertical {
            result = result.transformed(
                by: CGAffineTransform(
                    scaleX: effects.mirror ? -1 : 1, y: effects.mirrorVertical ? -1 : 1))
        }
        let extent = result.extent
        guard extent.width.isFinite, extent.height.isFinite,
            extent.width > 0, extent.height > 0
        else { return nil }
        result = result.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        if product.unmanagedBake {
            if cubeContext == nil {
                cubeContext = CIContext(options: MonitorWorkingSpace.contextOptions)
            }
            guard let cubeContext else { return nil }
            return (result, cubeContext, nil)
        }
        if displayContext == nil {
            displayContext = CIContext(options: MonitorWorkingSpace.displayContextOptions)
        }
        guard let displayContext else { return nil }
        // Default output space: sRGB, as `createCGImage` encodes.
        return (result, displayContext, Self.sRGB)
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
}

/// The admitted source is retained and read-only throughout this serial native job.
private struct InspectorImageBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

private final class InspectorImageWork: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

#endif
