#if os(iOS) && canImport(MetalKit) && canImport(MetalPerformanceShaders)
@preconcurrency import Metal
@preconcurrency import MetalKit
import Foundation
import UIKit

/// Push-model Metal picture presentation over the concrete shared bake/scaler owners.
/// UIKit view callbacks are main-confined; bake preparation remains on its own native queue.
public final class MonitorMetalPicturePresenter: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    public private(set) var drawableSize: CGSize = .zero
    public var onDrawableSizeChanged: ((CGSize) -> Void)?
    public var onPresentStart: (() -> Void)?
    public var onPresentEnd: (() -> Void)?
    private let baker: MonitorFrameBaker
    private let queue: MTLCommandQueue
    private let scaler: MonitorPresentScaler
    private let enabled: () -> Bool
    private let options: () -> MonitorPresentationOptions
    private weak var view: MTKView?
    private var closed = false
    #if DEBUG
        private let capture: MTLCaptureScope?
    #endif

    public init(device: MTLDevice, baker: MonitorFrameBaker,
        logSubsystem: String = "com.opencapture.opencine",
        captureLabel: String? = nil,
        enabled: @escaping () -> Bool = { true },
        options: @escaping () -> MonitorPresentationOptions = { .init() },
        qualityModelReady: @escaping @Sendable () -> Bool = { false }) {
        self.device = device
        self.baker = baker
        self.queue = device.makeCommandQueue()!
        self.scaler = MonitorPresentScaler(device: device, logSubsystem: logSubsystem,
            qualityModelReady: qualityModelReady)
        self.enabled = enabled
        self.options = options
        #if DEBUG
            if let captureLabel {
                let scope = MTLCaptureManager.shared().makeCaptureScope(commandQueue: queue)
                scope.label = captureLabel
                MTLCaptureManager.shared().defaultCaptureScope = scope
                capture = scope
            } else { capture = nil }
        #endif
        super.init()
    }

    /// UIKit host lifetime: main actor only, like the view delegate it assigns.
    @MainActor public func attach(_ candidate: MTKView) {
        guard !closed else { return }
        if let previous = view, previous !== candidate { previous.delegate = nil }
        view = candidate
        candidate.delegate = self
    }

    /// Puts `view` in the drawable format and dynamic range the current options ask for (A2-31):
    /// a float extended-range drawable while HDR display is on, 8-bit SDR otherwise. Bakes stay
    /// 8-bit display-referred either way; the present applies the HDR gain.
    @MainActor public func configureDisplay(_ view: MTKView) {
        let current = options()
        if view.colorPixelFormat != current.drawablePixelFormat {
            view.colorPixelFormat = current.drawablePixelFormat
        }
        if let layer = view.layer as? CAMetalLayer {
            MonitorHDRDisplay.configure(layer, enabled: current.hdr)
        }
    }

    public func noteDrawableSize(_ size: CGSize) {
        guard !closed, size.width > 0, size.height > 0, size != drawableSize else { return }
        drawableSize = size
        onDrawableSizeChanged?(size)
    }

    public func mtkView(_ candidate: MTKView, drawableSizeWillChange size: CGSize) {
        guard !closed, view === candidate, size.width > 0, size.height > 0 else { return }
        drawableSize = size
        onDrawableSizeChanged?(size)
        candidate.setNeedsDisplay()
    }

    public func draw(in candidate: MTKView) {
        autoreleasepool {
            guard !closed, view === candidate, enabled(), candidate.window != nil else { return }
            let size = candidate.drawableSize
            guard size.width > 0, size.height > 0 else { return }
            drawableSize = size
            guard let frame = baker.acquireFrame(for: size, pixelFormat: MonitorPresentationOptions.bakePixelFormat)
            else { return }
            let baked = frame.texture
            guard let drawable = candidate.currentDrawable,
                let command = queue.makeCommandBuffer()
            else {
                baker.releaseBakedTexture(baked)
                return
            }
            #if DEBUG
                capture?.begin()
            #endif
            onPresentStart?()
            defer {
                onPresentEnd?()
                #if DEBUG
                    capture?.end()
                #endif
            }
            guard scaler.encode(from: baked, to: drawable.texture,
                commandBuffer: command, overlay: frame.overlay, options: options()),
                frame.isCurrent, !closed, view === candidate
            else {
                baker.releaseBakedTexture(baked)
                return
            }
            // Completion owns the acquired bake even if the UIKit host closes
            // before native GPU sampling ends. Admission never spans GPU work.
            nonisolated(unsafe) let held = baked
            command.addCompletedHandler { [baker] _ in baker.releaseBakedTexture(held) }
            command.present(drawable)
            command.commit()
        }
    }

    @MainActor public func close() {
        guard !closed else { return }
        closed = true
        view?.delegate = nil
        view = nil
        onDrawableSizeChanged = nil
        onPresentStart = nil
        onPresentEnd = nil
        baker.close()
    }
}
#endif
