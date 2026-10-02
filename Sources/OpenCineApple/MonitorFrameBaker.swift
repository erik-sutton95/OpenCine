#if canImport(CoreImage) && canImport(Metal)
import CoreImage
import Foundation
import Metal

/// Evaluate the native look graph at feed/panel size off-main.
/// The native picture host scales the published texture into the drawable  -  no `createCGImage`.
public final class MonitorFrameBaker: @unchecked Sendable {
    /// Texture and source metadata are acquired together under the pool lock.
    public struct Frame: @unchecked Sendable {
        public let texture: MTLTexture
        public let drawableSize: CGSize
        public let pixelFormat: MTLPixelFormat
        public let id: UInt64
        public let generation: Int
        public let timeNs: Int64?
        public let unmanaged: Bool
        public let overlay: Bool
    }
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let lutContext: CIContext
    private let displayContext: CIContext
    private let workQueue = DispatchQueue(label: "opv.metal-feed-bake", qos: .userInitiated)
    private let lock = NSLock()
    private var pending:
        (
            image: CIImage, drawableSize: CGSize, pixelFormat: MTLPixelFormat, unmanaged: Bool,
            overlay: Bool, id: UInt64, generation: Int, timeNs: Int64?
        )?
    private var pendingDone: (@Sendable () -> Void)?
    private var busy = false
    private var textures: [MTLTexture] = []
    private var nextTexture = 0
    private var retained: [ObjectIdentifier: Int] = [:]
    private var baking: Set<ObjectIdentifier> = []
    private var published: Frame?
    private var nextFrameID: UInt64 = 0
    private static let depth = 3

    public init(device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()!
        self.lutContext = CIContext(
            mtlCommandQueue: commandQueue,
            options: MonitorWorkingSpace.contextOptions)
        self.displayContext = CIContext(
            mtlCommandQueue: commandQueue,
            options: MonitorWorkingSpace.displayContextOptions)
    }

    public func scheduleBake(
        image: CIImage, drawableSize: CGSize, pixelFormat: MTLPixelFormat,
        unmanaged: Bool = true, overlay: Bool = false,
        generation: Int = 0, timeNs: Int64? = nil,
        onComplete: @escaping @Sendable () -> Void
    ) {
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        lock.lock()
        nextFrameID &+= 1
        pending = (
            image, drawableSize, pixelFormat, unmanaged, overlay, nextFrameID, generation, timeNs
        )
        pendingDone = onComplete
        let start = !busy
        if start { busy = true }
        lock.unlock()
        if start { workQueue.async { [self] in run() } }
    }

    public func bakedTexture(for drawableSize: CGSize, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        acquireFrame(for: drawableSize, pixelFormat: pixelFormat)?.texture
    }

    public func acquireFrame(for drawableSize: CGSize, pixelFormat: MTLPixelFormat) -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        guard let published,
            published.drawableSize == drawableSize,
            published.pixelFormat == pixelFormat
        else { return nil }
        retained[ObjectIdentifier(published.texture), default: 0] += 1
        return published
    }

    public func releaseBakedTexture(_ texture: MTLTexture) {
        let key = ObjectIdentifier(texture)
        lock.lock()
        defer { lock.unlock() }
        guard let count = retained[key] else { return }
        if count <= 1 {
            retained[key] = nil
        } else {
            retained[key] = count - 1
        }
    }

    /// CI bottom-left → Metal/MPS origin. Preserve the source-to-bake orientation.
    public static func metalOriginTransform(extent: CGRect, bakeWidth: Int, bakeHeight: Int)
        -> CGAffineTransform
    {
        let sx = CGFloat(bakeWidth) / max(extent.width, 1)
        let sy = CGFloat(bakeHeight) / max(extent.height, 1)
        var transform = CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
        transform = transform.concatenating(CGAffineTransform(scaleX: sx, y: sy))
        transform = transform.concatenating(CGAffineTransform(scaleX: 1, y: -1))
        transform = transform.concatenating(
            CGAffineTransform(translationX: 0, y: CGFloat(bakeHeight)))
        return transform
    }

    /// Source resolution, downscale-bounded by the drawable. Preserve source aspect.
    public static func bakeSize(source: CGSize, drawable: CGSize) -> CGSize {
        guard source.width.isFinite, source.height.isFinite,
            source.width > 0, source.height > 0,
            source.width <= 16_384, source.height <= 16_384,
            drawable.width > 0, drawable.height > 0
        else { return drawable }
        let scale = min(drawable.width / source.width, drawable.height / source.height, 1)
        let fitted = CGSize(width: source.width * scale, height: source.height * scale)
        guard fitted.width >= 1, fitted.height >= 1 else { return drawable }
        return fitted
    }

    private func run() {
        lock.lock()
        guard let request = pending else {
            busy = false
            lock.unlock()
            return
        }
        pending = nil
        let done = pendingDone
        pendingDone = nil
        lock.unlock()

        let started = bake(
            request.image, drawableSize: request.drawableSize, pixelFormat: request.pixelFormat,
            unmanaged: request.unmanaged, overlay: request.overlay,
            id: request.id, generation: request.generation, timeNs: request.timeNs
        ) {
            done?()
        }
        if started {
            // Overlap the next cube while this one is still on the GPU.
            workQueue.async { [self] in run() }
            return
        }
        lock.lock()
        if pending == nil {
            pending = request
            pendingDone = done
        }
        let waitingGPU = !baking.isEmpty
        if !waitingGPU { busy = false }
        lock.unlock()
    }

    @discardableResult
    private func bake(
        _ source: CIImage, drawableSize: CGSize, pixelFormat: MTLPixelFormat,
        unmanaged: Bool, overlay: Bool, id: UInt64, generation: Int, timeNs: Int64?,
        finished: @escaping @Sendable () -> Void
    ) -> Bool {
        let extent = source.extent
        let size = Self.bakeSize(source: extent.size, drawable: drawableSize)
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        // CI is bottom-left,
        // MPS / Metal treat y=0 as the bottom of the picture. CAMetalLayer blit
        // of an unflipped bake is upright; Fast/Quality go through MPS, so the
        // bake must match that kernel or the picture lands upside down.
        let prepared =
            source
            .transformed(
                by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
            )
            .transformed(
                by: CGAffineTransform(
                    scaleX: CGFloat(width) / max(extent.width, 1),
                    y: CGFloat(height) / max(extent.height, 1))
            )
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1))
            .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(height)))
        guard
            let target = renderTexture(width: width, height: height, pixelFormat: pixelFormat),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return false
        }
        let context = unmanaged ? lutContext : displayContext
        let token = ObjectIdentifier(target)
        lock.lock()
        baking.insert(token)
        lock.unlock()
        context.render(
            prepared, to: target, commandBuffer: commandBuffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: MonitorWorkingSpace.metalDestination)
        let completedFrame = Frame(texture: target, drawableSize: drawableSize,
            pixelFormat: pixelFormat, id: id, generation: generation, timeNs: timeNs,
            unmanaged: unmanaged, overlay: overlay)
        commandBuffer.addCompletedHandler { [self] command in
            lock.lock()
            baking.remove(token)
            if command.status == .completed, id > (published?.id ?? 0) {
                published = completedFrame
            }
            lock.unlock()
            finished()
            workQueue.async { [self] in run() }
        }
        commandBuffer.commit()
        return true
    }

    private func renderTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> MTLTexture?
    {
        lock.lock()
        defer { lock.unlock() }
        let matches =
            textures.count == Self.depth
            && textures.allSatisfy {
                $0.width == width && $0.height == height && $0.pixelFormat == pixelFormat
            }
        if !matches {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            let built = (0..<Self.depth).compactMap { _ in
                device.makeTexture(descriptor: descriptor)
            }
            guard built.count == Self.depth else { return nil }
            textures = built
            nextTexture = 0
            retained = retained.filter { key, _ in
                textures.contains { ObjectIdentifier($0) == key }
            }
        }
        for offset in 0..<textures.count {
            let index = (nextTexture + offset) % textures.count
            let texture = textures[index]
            let id = ObjectIdentifier(texture)
            if retained[id] == nil, !baking.contains(id), published?.texture !== texture {
                nextTexture = index + 1
                return texture
            }
        }
        return nil
    }
}
#endif
