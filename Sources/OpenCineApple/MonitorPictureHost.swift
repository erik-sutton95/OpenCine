#if canImport(UIKit) && canImport(CoreImage) && canImport(Metal)
import CoreImage
import Foundation
import Metal
import QuartzCore
import UIKit
import OpenCineMedia

private struct MonitorPresentBox<Value>: @unchecked Sendable {
    let value: Value
}

/// Injectable Metal boundary: acquisition may block, submission completes asynchronously.
public struct MonitorPresentOperations: @unchecked Sendable {
    public var acquire: @Sendable (CAMetalLayer) -> CAMetalDrawable? = { $0.nextDrawable() }
    public var encode: (@Sendable (MonitorFrameBaker.Frame, MTLTexture, MTLCommandBuffer) -> Bool)?
    public var submit:
        @Sendable (
            MTLCommandBuffer, CAMetalDrawable, @escaping @Sendable (Bool) -> Void
        ) -> Void = { command, drawable, completed in
            command.addCompletedHandler { completed($0.status == .completed) }
            command.present(drawable)
            command.commit()
        }
    public init(acquire: @escaping @Sendable (CAMetalLayer) -> CAMetalDrawable? = { $0.nextDrawable() },
        encode: (@Sendable (MonitorFrameBaker.Frame, MTLTexture, MTLCommandBuffer) -> Bool)? = nil,
        submit: @escaping @Sendable (MTLCommandBuffer, CAMetalDrawable,
            @escaping @Sendable (Bool) -> Void) -> Void = { command, drawable, completed in
                command.addCompletedHandler { completed($0.status == .completed) }
                command.present(drawable); command.commit()
            }) {
        self.acquire = acquire; self.encode = encode; self.submit = submit
    }
}

/// Metal-backed presenter. Baking, scaling and model preparation run off-main.
open class MonitorPictureHost: UIView {
    /// A native runtime may adopt the same retained host before its predecessor retires.
    public final class Ownership { fileprivate init() {} }
    private var currentOwner: Ownership?
    public func claimOwnership() -> Ownership {
        invalidatePendingPresents()
        resetPresentDedup()
        let owner = Ownership()
        currentOwner = owner
        return owner
    }
    public func owns(_ owner: Ownership?) -> Bool {
        owner != nil && currentOwner === owner
    }
    public func releaseOwnership(_ owner: Ownership?) {
        guard owns(owner) else { return }
        currentOwner = nil
        onPresented = nil
    }

    public override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let device: MTLDevice?
    private let renderer: MonitorPresentRenderer
    private let baker: MonitorFrameBaker?
    /// Presents commit here and complete on the GPU  -  never a synchronous render on main.
    private let presentQueue: MTLCommandQueue?
    /// First successful present. Until then the VT layer must stay visible  -
    /// this view is opaque black and `display` returns before the bake lands.
    public private(set) var hasPresentedFrame = false
    /// Last successful present was transparent zebra / peaking / false colour.
    /// LUT must not treat that as replace-ownership.
    public private(set) var lastPresentWasOverlay = false
    /// Offscreen / scrolling-off views skip Metal. Native work follows this host's display demand.
    public var isEnabled = true
    /// Playback (and live LUT replace) adopt the metal picture after this fires.
    public var onPresented: (() -> Void)?
    public private(set) var lastPresentedTimeNs: Int64?
    private var lastPresentedBakeID: UInt64 = 0
    private let drawableQueue = DispatchQueue(label: "opv.feed-drawable", qos: .userInitiated)
    private var presentGeneration = 0
    private var inFlightPresents = 0
    private var pendingPresent = false
    public var presentOperations = MonitorPresentOperations()
    public private(set) var lastPresentedAt: Date?
    public private(set) var presentedFrames = 0
    public private(set) var skippedDuplicates = 0
    public private(set) var skippedDisabled = 0
    public private(set) var skippedDrawableBusy = 0
    public private(set) var failedPresents = 0
    private var presentationMetrics = MonitorPresentationMetrics(
        startedAt: ProcessInfo.processInfo.systemUptime)
    /// View bounds in pixels. The drawable can be smaller; see ``presentDrawableSize``.
    private var panelPixelSize = CGSize.zero
    private var lastSourceSize = CGSize.zero

    public var isRendering: Bool {
        !FeedPresentPolicy.isFrozen(
            secondsSinceLastPresent: lastPresentedAt.map { Date().timeIntervalSince($0) })
            && hasPresentedFrame
    }

    public var debugLine: String {
        let timing = presentationMetrics.drain(at: ProcessInfo.processInfo.systemUptime)
        let rate = String(format: "%.1f", timing?.gpuFramesPerSecond ?? 0)
        return "feed present gpuFPS=\(rate) gpuGapMs=\(Int(timing?.maximumGapMilliseconds ?? 0)) "
            + "first=\(hasPresentedFrame ? 1 : 0) frozen=\(isRendering ? 0 : 1) overlay=\(lastPresentWasOverlay ? 1 : 0) "
            + "skipDup=\(skippedDuplicates) skipOff=\(skippedDisabled) skipBusy=\(skippedDrawableBusy) failed=\(failedPresents) "
            + "acquireMaxMs=\(Int(timing?.maximumAcquireMilliseconds ?? 0)) "
            + "gpuMaxMs=\(Int(timing?.maximumGPUCompletionMilliseconds ?? 0))"
    }

    private let optionsProvider: @MainActor (UIScreen?) -> MonitorPresentationOptions
    private var presentationOptions = MonitorPresentationOptions()
    public var onSuccessfulPresent: (() -> Void)?
    public override convenience init(frame: CGRect) {
        self.init(frame: frame, options: { _ in .init() })
    }
    public init(frame: CGRect, options: @escaping @MainActor (UIScreen?) -> MonitorPresentationOptions,
        logSubsystem: String = "com.opencapture.opencine") {
        self.optionsProvider = options
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        self.renderer = MonitorPresentRenderer(device: device, logSubsystem: logSubsystem)
        self.baker = device.map { MonitorFrameBaker(device: $0) }
        self.presentQueue = device?.makeCommandQueue()
        super.init(frame: frame)
        isOpaque = true
        isHidden = true
        backgroundColor = .black
        metalLayer.device = device
        metalLayer.pixelFormat = MonitorPresentationOptions.bakePixelFormat
        metalLayer.framebufferOnly = false
        metalLayer.contentsScale = UIScreen.main.scale
        // Timeout can still wait one second. Acquisition runs on drawableQueue,
        // with one reservation covering both acquisition and GPU completion.
        metalLayer.allowsNextDrawableTimeout = true
        // A source-sized drawable is aspect-fitted by the compositor, like the
        // identity layer. A panel-sized drawable has the bounds' aspect, so this is a no-op there.
        metalLayer.contentsGravity = .resizeAspect
        syncHDRDisplay()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        syncHDRDisplay()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let size = bounds.size
        if size.width > 1, size.height > 1 {
            let next = CGSize(width: size.width * scale, height: size.height * scale)
            if panelPixelSize != next {
                invalidatePendingPresents()
                resetPresentDedup()
                panelPixelSize = next
            }
            applyDrawableSize()
        }
    }

    /// Bilinear (Off / Fast) SDR presents at bake size: the compositor already
    /// scales this layer while compositing, so a panel-sized MPS bilinear pass and
    /// clear only added memory traffic for the same filter. Quality / AI need panel
    /// pixels to enlarge into, and HDR keeps its gain pass at panel size.
    public static func presentDrawableSize(
        source: CGSize, panel: CGSize, upscaler: MonitorUpscaler, hdr: Bool
    ) -> CGSize {
        guard !hdr, upscaler == .off || upscaler == .lanczos,
            source.width > 1, source.height > 1
        else { return panel }
        let fitted = MonitorFrameBaker.bakeSize(source: source, drawable: panel)
        return CGSize(width: fitted.width.rounded(), height: fitted.height.rounded())
    }

    private func applyDrawableSize() {
        guard panelPixelSize.width > 1, panelPixelSize.height > 1 else { return }
        let next = Self.presentDrawableSize(
            source: lastSourceSize, panel: panelPixelSize,
            upscaler: presentationOptions.upscaler, hdr: presentationOptions.hdr)
        guard next.width > 1, next.height > 1, metalLayer.drawableSize != next else { return }
        invalidatePendingPresents()
        resetPresentDedup()
        metalLayer.drawableSize = next
    }

    public func setOverlayChrome(_ overlay: Bool) {
        isOpaque = !overlay
        backgroundColor = overlay ? .clear : .black
        metalLayer.isOpaque = !overlay
    }

    public func syncHDRDisplay() {
        let options = optionsProvider(window?.screen ?? UIScreen.main)
        presentationOptions = options
        if metalLayer.pixelFormat != options.drawablePixelFormat
            || metalLayer.wantsExtendedDynamicRangeContent != options.hdr {
            invalidatePendingPresents(); resetPresentDedup()
        }
        MonitorHDRDisplay.configure(metalLayer, enabled: options.hdr)
    }

    public func resetPresentDedup() {
        lastPresentedTimeNs = nil
    }

    /// Next clip / new look. Stale `hasPresentedFrame` would hide the new
    /// identity under the previous LUT until the chip is cycled.
    public func resetPresentation() {
        invalidatePendingPresents()
        resetPresentDedup()
        hideForLayerPlan()
    }

    /// Hide the metal plate without dropping an in-flight bake. SwiftUI
    /// `attach` runs every pass  -  bumping `presentGeneration` here cancels the
    /// LUT cube that `present` just scheduled, then unhides an empty layer.
    public func hideForLayerPlan() {
        hasPresentedFrame = false
        lastPresentWasOverlay = false
        lastPresentedAt = nil
        setOverlayChrome(false)
        isHidden = true
    }

    public var debugPresentGeneration: Int { presentGeneration }

    /// Drop in-flight bakes (LUT off, feed detached). A late replace present
    /// must not unhide an opaque plate over identity.
    public func invalidatePendingPresents() {
        presentGeneration += 1
        pendingPresent = false
    }

    @discardableResult
    public func display(
        _ image: CIImage, unmanaged: Bool = true, overlay: Bool = false, timeNs: Int64? = nil
    ) -> Bool {
        if FeedPresentPolicy.isDuplicateFrameTime(timeNs ?? 0, lastPresentedNs: lastPresentedTimeNs ?? 0) {
            skippedDuplicates += 1
            return hasPresentedFrame
        }
        syncHDRDisplay()
        if isEnabled, image.extent.width > 1, image.extent.height > 1 {
            lastSourceSize = image.extent.size
            applyDrawableSize()
        }
        let size = metalLayer.drawableSize
        let hasDrawable = size.width > 1 && size.height > 1
        guard
            FeedPresentPolicy.shouldScheduleBake(enabled: isEnabled, hasDrawable: hasDrawable)
        else {
            skippedDisabled += 1
            return false
        }
        guard image.extent.width > 1, image.extent.height > 1 else { return false }
        let generation = presentGeneration
        if let baker {
            baker.scheduleBake(
                image: image, drawableSize: size, pixelFormat: MonitorPresentationOptions.bakePixelFormat,
                unmanaged: unmanaged, overlay: overlay, generation: generation, timeNs: timeNs
            ) { [weak self] in
                DispatchQueue.main.async { self?.presentLatestBake(generation: generation) }
            }
            return true
        }
        return false
    }

    /// Acquisition may wait for Core Animation; MainActor remains free to ingest
    /// video and handle lifecycle changes. Only one acquisition/GPU flight exists.
    private func presentLatestBake(generation: Int) {
        guard generation == presentGeneration, isEnabled, let baker else { return }
        guard inFlightPresents == 0 else {
            skippedDrawableBusy += 1
            pendingPresent = true
            return
        }
        let size = metalLayer.drawableSize
        guard let frame = baker.acquireFrame(for: size, pixelFormat: MonitorPresentationOptions.bakePixelFormat)
        else { return }
        guard frame.generation == generation, frame.id > lastPresentedBakeID,
            !FeedPresentPolicy.isDuplicateFrameTime(
                frame.timeNs ?? 0, lastPresentedNs: lastPresentedTimeNs ?? 0)
        else {
            skippedDuplicates += 1
            baker.releaseBakedTexture(frame.texture)
            return
        }
        if FeedPresentPolicy.unhideMetalBeforeBake(overlay: frame.overlay) {
            // Keep identity visible while the first drawable is being acquired.
            if !hasPresentedFrame { alpha = 0 }
            isHidden = false
        }
        inFlightPresents = 1
        let operations = presentOperations
        let layer = MonitorPresentBox(value: metalLayer)
        drawableQueue.async { [weak self] in
            let started = ProcessInfo.processInfo.systemUptime
            let drawable = MonitorPresentBox(value: operations.acquire(layer.value))
            let acquireMs = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    baker.releaseBakedTexture(frame.texture)
                    return
                }
                self.presentationMetrics.noteAcquire(milliseconds: acquireMs)
                self.submitAcquiredFrame(
                    frame, drawable: drawable.value, operations: operations, baker: baker)
            }
        }
    }

    private func submitAcquiredFrame(
        _ frame: MonitorFrameBaker.Frame, drawable: CAMetalDrawable?,
        operations: MonitorPresentOperations, baker: MonitorFrameBaker
    ) {
        guard frame.generation == presentGeneration, isEnabled,
            frame.drawableSize == metalLayer.drawableSize, let drawable,
            let commandBuffer = presentQueue?.makeCommandBuffer()
        else {
            baker.releaseBakedTexture(frame.texture)
            failedPresents += 1
            if frame.generation == presentGeneration, !hasPresentedFrame {
                isHidden = true
                alpha = 1
            }
            finishPresentFlight()
            return
        }
        let renderer = self.renderer
        let options = presentationOptions
        let resources = MonitorPresentBox(value: (drawable, commandBuffer))
        drawableQueue.async { [weak self] in
            let (drawable, commandBuffer) = resources.value
            let encoded =
                operations.encode?(frame, drawable.texture, commandBuffer)
                ?? renderer.encode(frame, to: drawable.texture, commandBuffer: commandBuffer, options: options)
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    baker.releaseBakedTexture(frame.texture)
                    return
                }
                self.submitPreparedFrame(
                    frame, resources: resources, encoded: encoded,
                    operations: operations, baker: baker)
            }
        }
    }

    private func submitPreparedFrame(
        _ frame: MonitorFrameBaker.Frame,
        resources: MonitorPresentBox<(CAMetalDrawable, MTLCommandBuffer)>, encoded: Bool,
        operations: MonitorPresentOperations, baker: MonitorFrameBaker
    ) {
        // Rotation, coverage or recovery can invalidate the frame while a
        // native upscaler is preparing. Never submit that retired drawable.
        guard encoded, frame.generation == presentGeneration, isEnabled,
            frame.drawableSize == metalLayer.drawableSize
        else {
            baker.releaseBakedTexture(frame.texture)
            failedPresents += 1
            finishPresentFlight()
            return
        }
        let (drawable, commandBuffer) = resources.value
        let submittedAt = ProcessInfo.processInfo.systemUptime
        operations.submit(commandBuffer, drawable) { [weak self] success in
            // GPU has finished reading the pool slot, on success or failure.
            baker.releaseBakedTexture(frame.texture)
            let completedAt = Date()
            let gpuMs = (ProcessInfo.processInfo.systemUptime - submittedAt) * 1_000
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.presentationMetrics.noteGPUCompletion(milliseconds: gpuMs)
                if frame.generation == self.presentGeneration, self.isEnabled,
                    frame.drawableSize == self.metalLayer.drawableSize
                {
                    if success {
                        self.onSuccessfulPresent?()
                        self.notePresented(frame, at: completedAt)
                        self.onPresented?()
                    } else {
                        self.failedPresents += 1
                        if !self.hasPresentedFrame { self.isHidden = true }
                    }
                }
                self.finishPresentFlight()
            }
        }
    }

    private func finishPresentFlight() {
        inFlightPresents = 0
        guard pendingPresent else { return }
        pendingPresent = false
        presentLatestBake(generation: presentGeneration)
    }

    private func notePresented(_ frame: MonitorFrameBaker.Frame, at completedAt: Date) {
        let overlay = frame.overlay
        setOverlayChrome(overlay)
        lastPresentedBakeID = frame.id
        alpha = 1
        hasPresentedFrame = true
        lastPresentWasOverlay = overlay
        lastPresentedTimeNs = frame.timeNs
        lastPresentedAt = completedAt
        presentedFrames += 1
        presentationMetrics.notePresented(at: ProcessInfo.processInfo.systemUptime)
        // Overlay only: identity stays on the HEVC / VT layer. Unhiding an
        // opaque identity bake here is a black plate over a working picture.
        if overlay {
            isHidden = false
        }
    }
}

/// Confined to the presenter's serial drawable worker. It owns no UIKit state.
private final class MonitorPresentRenderer: @unchecked Sendable {
    private let lutContext: CIContext
    private let displayContext: CIContext
    private let presentScaler: MonitorPresentScaler?

    init(device: MTLDevice?, logSubsystem: String) {
        let lutOptions = MonitorWorkingSpace.contextOptions
        let displayOptions = MonitorWorkingSpace.displayContextOptions
        lutContext =
            device.map { CIContext(mtlDevice: $0, options: lutOptions) }
            ?? CIContext(options: lutOptions)
        displayContext =
            device.map { CIContext(mtlDevice: $0, options: displayOptions) }
            ?? CIContext(options: displayOptions)
        presentScaler = device.map { MonitorPresentScaler(device: $0, logSubsystem: logSubsystem) }
    }

    /// Bake is source-sized (`bakeSize` never enlarges). Off / Fast / Quality / AI enlarge
    /// it to the drawable with the selected native scale policy.
    func encode(
        _ frame: MonitorFrameBaker.Frame, to target: MTLTexture, commandBuffer: MTLCommandBuffer,
        options: MonitorPresentationOptions
    ) -> Bool {
        let baked = frame.texture
        let overlay = frame.overlay
        if let presentScaler,
            presentScaler.encode(
                from: baked, to: target, commandBuffer: commandBuffer, overlay: overlay, options: options)
        {
            return true
        }
        if baked.pixelFormat == target.pixelFormat,
            baked.width <= target.width, baked.height <= target.height,
            baked.width == target.width || baked.height == target.height
        {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: 0, green: 0, blue: 0, alpha: overlay ? 0 : 1)
            guard let clear = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
            else { return false }
            clear.endEncoding()
            guard let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
            blit.copy(
                from: baked, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: baked.width, height: baked.height, depth: 1),
                to: target, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(
                    x: (target.width - baked.width) / 2,
                    y: (target.height - baked.height) / 2,
                    z: 0))
            blit.endEncoding()
            return true
        }
        let unmanaged = frame.unmanaged
        let options =
            unmanaged
            ? MonitorWorkingSpace.imageOptions
            : MonitorWorkingSpace.displayImageOptions
        guard let image = CIImage(mtlTexture: baked, options: options) else { return false }
        let dest = CGRect(
            origin: .zero, size: CGSize(width: target.width, height: target.height))
        let fitted = Self.aspectFit(image, in: dest)
        let backdrop = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: overlay ? 0 : 1))
            .cropped(to: dest)
        let context = unmanaged ? lutContext : displayContext
        context.render(
            fitted.composited(over: backdrop), to: target, commandBuffer: commandBuffer,
            bounds: dest, colorSpace: MonitorWorkingSpace.metalDestination)
        return true
    }

    private static func aspectFit(_ image: CIImage, in dest: CGRect) -> CIImage {
        let src = image.extent
        guard src.width > 0, src.height > 0 else { return image }
        let scale = min(dest.width / src.width, dest.height / src.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let e = scaled.extent
        let dx = dest.midX - e.midX
        let dy = dest.midY - e.midY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }
}
#endif
