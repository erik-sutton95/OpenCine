#if os(iOS)
import CoreImage
import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders
import OpenCineMedia

public struct MonitorBackdropRasterLayer: @unchecked Sendable {
    public var image: CGImage
    public var frame: CGRect
    public var clip: CGRect
    public init(image: CGImage, frame: CGRect, clip: CGRect) {
        self.image = image; self.frame = frame; self.clip = clip
    }
}
public struct MonitorBackdropRasterSnapshot: @unchecked Sendable {
    public let canvasSize: CGSize
    private let images: [MonitorBackdropBlurProduct: CGImage]
    public init(canvasSize: CGSize, images: [MonitorBackdropBlurProduct: CGImage]) {
        self.canvasSize = canvasSize; self.images = images
    }
    public func image(for product: MonitorBackdropBlurProduct) -> CGImage? { images[product] }
}

    /// Run on one retained utility worker. Four bounded raster products serve all
    /// seven roles; there is no panel readback, screenshot or private backdrop API.
    public final class MonitorBackdropRasterRenderer {
        private typealias FilterKey = MonitorBackdropBlurProduct
        private let productKeys: [FilterKey]
        private let context: CIContext
        private let gpu = MonitorBackdropGPU.make()

        public init(products: [MonitorBackdropBlurProduct]) {
            productKeys = MonitorBackdropRenderValues.distinctProducts(products)
            let options: [CIContextOption: Any] = [
                .workingColorSpace: NSNull(), .cacheIntermediates: false,
                .useSoftwareRenderer: false,
            ]
            if let gpu {
                context = CIContext(mtlDevice: gpu.device, options: options)
            } else {
                context = CIContext(options: options)
            }
        }

        public func render(
            canvasSize: CGSize, layers: [MonitorBackdropRasterLayer], surroundRGB: UInt32 = 0x08090A
        )
            -> MonitorBackdropRasterSnapshot?
        {
            guard let (scale, extent) = Self.geometry(canvasSize), !layers.isEmpty, !productKeys.isEmpty else { return nil }
            let canvas = Self.canvas(
                canvasSize: canvasSize, scale: scale, extent: extent, surroundRGB: surroundRGB,
                placed: layers.map { (CIImage(cgImage: $0.image), $0.frame, $0.clip) })
            let keys = productKeys
            if let gpu,
                let rendered = gpu.render(
                    canvas: canvas, extent: extent, context: context, colorSpace: nil,
                    products: keys.map { ($0.radius * scale, $0.saturation) })
            {
                return Self.snapshot(canvasSize: canvasSize, keys: keys, rendered: rendered)
            }
            // Core Image fallback (no Metal / MPS).
            // Build every distinct blur product, stack them in one atlas and
            // render that once. Each Core Image render carries fixed CPU setup
            // (graph tiling, intermediate surfaces, a synchronous GPU wait), so
            // one render instead of four is most of this job's CPU. The crops
            // share the atlas bitmap (no copy).
            var atlas = CIImage.empty()
            for (index, key) in keys.enumerated() {
                // Clamp the complete canvas before convolution. Panel clipping
                // happens afterward, so edges can sample beyond the panel bounds.
                let filtered = canvas.clampedToExtent()
                    .applyingFilter(
                        "CIGaussianBlur",
                        parameters: [
                            kCIInputRadiusKey: key.radius * scale
                        ]
                    )
                    .applyingFilter(
                        "CIColorControls",
                        parameters: [
                            kCIInputSaturationKey: key.saturation
                        ]
                    )
                    .cropped(to: extent)
                    .transformed(
                        by: CGAffineTransform(
                            translationX: 0, y: CGFloat(index) * extent.height))
                atlas = filtered.composited(over: atlas)
            }
            let atlasRect = CGRect(
                x: 0, y: 0, width: extent.width, height: extent.height * CGFloat(keys.count))
            guard let rendered = context.createCGImage(atlas, from: atlasRect) else { return nil }
            var products: [FilterKey: CGImage] = [:]
            for (index, key) in keys.enumerated() {
                // CGImage rows run top-down; atlas slot 0 is at the bottom.
                let top = CGFloat(keys.count - 1 - index) * extent.height
                guard
                    let image = rendered.cropping(
                        to: CGRect(x: 0, y: top, width: extent.width, height: extent.height))
                else { return nil }
                products[key] = image
            }
            return MonitorBackdropRasterSnapshot(canvasSize: canvasSize, images: products)
        }

        /// Single-source fast path: `lookContext` renders the look straight into the
        /// canvas texture, so there is no CGImage readback, CPU image or re-upload.
        /// `outputColorSpace` is the encoding that context's `createCGImage` would
        /// use (nil when unmanaged), which keeps the pixels the same. Nil without
        /// Metal; the caller then uses the CGImage path.
        public func render(
            canvasSize: CGSize, look: CIImage, frame: CGRect, clip: CGRect,
            lookContext: CIContext, outputColorSpace: CGColorSpace?,
            surroundRGB: UInt32 = 0x08090A
        ) -> MonitorBackdropRasterSnapshot? {
            guard let gpu, let (scale, extent) = Self.geometry(canvasSize),
                look.extent.width > 0, look.extent.height > 0, !productKeys.isEmpty
            else { return nil }
            let canvas = Self.canvas(
                canvasSize: canvasSize, scale: scale, extent: extent, surroundRGB: surroundRGB,
                placed: [(look, frame, clip)])
            let keys = productKeys
            guard
                let rendered = gpu.render(
                    canvas: canvas, extent: extent, context: lookContext,
                    colorSpace: outputColorSpace,
                    products: keys.map { ($0.radius * scale, $0.saturation) })
            else { return nil }
            return Self.snapshot(canvasSize: canvasSize, keys: keys, rendered: rendered)
        }

        private static func geometry(_ canvasSize: CGSize) -> (CGFloat, CGRect)? {
            guard let size = MonitorBackdropRenderValues.rasterSize(
                width: Double(canvasSize.width), height: Double(canvasSize.height)) else { return nil }
            return (CGFloat(size.scale), CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }

        /// Places each image (origin at zero) in its canvas frame and clip over the surround.
        private static func canvas(
            canvasSize: CGSize, scale: CGFloat, extent: CGRect, surroundRGB: UInt32,
            placed: [(image: CIImage, frame: CGRect, clip: CGRect)]
        ) -> CIImage {
            // Tagged sRGB: an unmanaged context uses the bytes as-is, a managed look
            // context round-trips them, so the surround is identical either way.
            let red = CGFloat((surroundRGB >> 16) & 255) / 255
            let green = CGFloat((surroundRGB >> 8) & 255) / 255
            let blue = CGFloat(surroundRGB & 255) / 255
            let color =
                CGColorSpace(name: CGColorSpace.sRGB).flatMap {
                    CIColor(red: red, green: green, blue: blue, colorSpace: $0)
                } ?? CIColor(red: red, green: green, blue: blue)
            var canvas = CIImage(color: color).cropped(to: extent)
            for layer in placed {
                let frame = layer.frame
                let size = layer.image.extent.size
                guard frame.width > 0, frame.height > 0, size.width > 0, size.height > 0
                else { continue }
                let image = layer.image.transformed(
                    by: CGAffineTransform(
                        scaleX: frame.width * scale / size.width,
                        y: frame.height * scale / size.height)
                ).transformed(
                    by: CGAffineTransform(
                        translationX: frame.minX * scale,
                        y: (canvasSize.height - frame.maxY) * scale))
                let clip = CGRect(
                    x: layer.clip.minX * scale,
                    y: (canvasSize.height - layer.clip.maxY) * scale,
                    width: layer.clip.width * scale, height: layer.clip.height * scale)
                canvas = image.cropped(to: clip).composited(over: canvas)
            }
            return canvas.cropped(to: extent)
        }

        private static func snapshot(canvasSize: CGSize, keys: [FilterKey], rendered: [CGImage])
            -> MonitorBackdropRasterSnapshot {
            MonitorBackdropRasterSnapshot(canvasSize: canvasSize,
                images: Dictionary(uniqueKeysWithValues: zip(keys, rendered)))
        }
    }

    /// Metal backdrop products. Core Image only composites the small canvas into a
    /// half-float texture; saturation (linear, so it commutes with the blur) and
    /// clamped-edge Gaussian blurs run as one Metal command buffer, followed by a
    /// single small readback per product. Core Image's own blur built a fresh
    /// intermediate-surface pyramid per product on every job, which was most of
    /// this path's CPU on device.
    final class MonitorBackdropGPU {
        let device: MTLDevice
        private let queue: MTLCommandQueue
        private let saturate: MTLComputePipelineState
        private var textures: [String: MTLTexture] = [:]
        private var blurs: [Double: MPSImageGaussianBlur] = [:]

        private init(device: MTLDevice, queue: MTLCommandQueue, saturate: MTLComputePipelineState) {
            self.device = device
            self.queue = queue
            self.saturate = saturate
        }

        static func make() -> MonitorBackdropGPU? {
            guard let device = MTLCreateSystemDefaultDevice(),
                MPSSupportsMTLDevice(device),
                let queue = device.makeCommandQueue(),
                let library = try? device.makeLibrary(source: saturateSource, options: nil),
                let function = library.makeFunction(name: "backdrop_saturate"),
                let saturate = try? device.makeComputePipelineState(function: function)
            else { return nil }
            return MonitorBackdropGPU(device: device, queue: queue, saturate: saturate)
        }

        /// Rec. 709 luma weights, as `CIColorControls` uses.
        private static let saturateSource = """
            #include <metal_stdlib>
            using namespace metal;
            kernel void backdrop_saturate(
                texture2d<half, access::read> src [[texture(0)]],
                texture2d<half, access::write> dst [[texture(1)]],
                constant float &amount [[buffer(0)]],
                uint2 gid [[thread_position_in_grid]])
            {
                if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
                half4 c = src.read(gid);
                half luma = dot(c.rgb, half3(0.2125h, 0.7154h, 0.0721h));
                dst.write(half4(mix(half3(luma), c.rgb, half(amount)), c.a), gid);
            }
            """

        private func texture(_ name: String, _ width: Int, _ height: Int, _ format: MTLPixelFormat)
            -> MTLTexture?
        {
            if let t = textures[name], t.width == width, t.height == height { return t }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = format == .bgra8Unorm ? .shared : .private
            let t = device.makeTexture(descriptor: descriptor)
            textures[name] = t
            return t
        }

        /// One image per `(sigma, saturation)` product, in order, or nil to fall back.
        /// Products are rendered while the previous job's images may still be
        /// displayed, so each readback copies into its own CGImage buffer.
        func render(
            canvas: CIImage, extent: CGRect, context: CIContext, colorSpace: CGColorSpace?,
            products: [(sigma: Double, saturation: Double)]
        ) -> [CGImage]? {
            let width = Int(extent.width)
            let height = Int(extent.height)
            // Sigmas follow the canvas scale; keep only this size's kernels.
            if let canvas = textures["canvas"], canvas.width != width || canvas.height != height {
                blurs.removeAll()
            }
            guard width > 0, height > 0,
                let command = queue.makeCommandBuffer(),
                let source = texture("canvas", width, height, .rgba16Float)
            else { return nil }
            let destination = CIRenderDestination(mtlTexture: source, commandBuffer: command)
            destination.isFlipped = true
            // nil: unmanaged bytes, as the NSNull-working-space CGImage path; a
            // managed look context passes the sRGB encoding createCGImage uses.
            destination.colorSpace = colorSpace
            guard (try? context.startTask(toRender: canvas, from: extent, to: destination, at: .zero))
                != nil
            else { return nil }
            var saturated: [Double: MTLTexture] = [1: source]
            var outputs: [MTLTexture] = []
            for (index, product) in products.enumerated() {
                var input = saturated[product.saturation]
                if input == nil {
                    guard
                        let target = texture(
                            "sat-\(product.saturation)", width, height, .rgba16Float),
                        let encoder = command.makeComputeCommandEncoder()
                    else { return nil }
                    var amount = Float(product.saturation)
                    encoder.setComputePipelineState(saturate)
                    encoder.setTexture(source, index: 0)
                    encoder.setTexture(target, index: 1)
                    encoder.setBytes(&amount, length: MemoryLayout<Float>.size, index: 0)
                    let group = MTLSize(width: 16, height: 16, depth: 1)
                    encoder.dispatchThreadgroups(
                        MTLSize(
                            width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
                        threadsPerThreadgroup: group)
                    encoder.endEncoding()
                    saturated[product.saturation] = target
                    input = target
                }
                guard let input, let output = texture("out-\(index)", width, height, .bgra8Unorm)
                else { return nil }
                let blur =
                    blurs[product.sigma]
                    ?? {
                        let made = MPSImageGaussianBlur(device: device, sigma: Float(product.sigma))
                        made.edgeMode = .clamp
                        blurs[product.sigma] = made
                        return made
                    }()
                blur.encode(commandBuffer: command, sourceTexture: input, destinationTexture: output)
                outputs.append(output)
            }
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else { return nil }
            let rowBytes = width * 4
            let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let info = CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
            var images: [CGImage] = []
            for output in outputs {
                var bytes = Data(count: rowBytes * height)
                bytes.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    output.getBytes(
                        base, bytesPerRow: rowBytes,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                }
                guard let provider = CGDataProvider(data: bytes as CFData),
                    let image = CGImage(
                        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: rowBytes, space: space, bitmapInfo: info,
                        provider: provider, decode: nil, shouldInterpolate: true,
                        intent: .defaultIntent)
                else { return nil }
                images.append(image)
            }
            return images
        }
    }

#endif
