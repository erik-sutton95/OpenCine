#if canImport(UIKit) && canImport(CoreImage)
import CoreImage
import OpenCineMedia
import UIKit

/// A source-qualified cube identity and bounded byte lookup. The native owner caches the filter.
public struct MonitorNativeCubeRequest {
    public var key: String
    public var resolve: () -> (dimension: Int, rgba: Data)?
    public init(key: String, resolve: @escaping () -> (dimension: Int, rgba: Data)?) {
        self.key = key; self.resolve = resolve
    }
}

public enum MonitorUIImageLook {
    case plain
    case grade(MonitorNativeCubeRequest, splitVertical: Bool?)
    case replacement(MonitorNativeCubeRequest)
    case limits(grade: MonitorNativeCubeRequest?, splitVertical: Bool?, paint: MonitorNativeCubeRequest, weight: MonitorNativeCubeRequest)

    fileprivate var cubeKeys: [String] {
        switch self {
        case .plain: return []
        case .grade(let cube, _), .replacement(let cube): return [cube.key]
        case .limits(let grade, _, let paint, let weight):
            return [grade?.key, paint.key, weight.key].compactMap { $0 }
        }
    }
}

public struct MonitorPeakingOverlay {
    public var color: MonitorRGB
    public var sensitivity: MonitorPeakingSensitivity
    public var gateScale: Double
    public var fusedWindowPolicy: MonitorPeakingFusedWindowPolicy
    public init(color: MonitorRGB, sensitivity: MonitorPeakingSensitivity, gateScale: Double = 1,
        fusedWindowPolicy: MonitorPeakingFusedWindowPolicy = .extendedAnalysisWindow) {
        self.color = color; self.sensitivity = sensitivity; self.gateScale = gateScale
        self.fusedWindowPolicy = fusedWindowPolicy
    }
}

public struct MonitorUIImageGraph {
    public var look: MonitorUIImageLook = .plain
    public var smoothing: MonitorBlockSmoothing?
    public var dither: MonitorBlockDither?
    public var peaking: MonitorPeakingOverlay?
    public var zebra: MonitorCodeZebraSpec?
    public init() {}
}

/// Actor/serial-queue-confined UIImage graph and readback owner. Settings equality remains exact.
public final class MonitorUIImageGraphProcessor<Settings: Equatable> {
    private static var displaySpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }
    private let context: CIContext
    private let outputColorSpace: CGColorSpace
    private let beginReadback: () -> Void
    private let endReadback: () -> Void
    private var cubeFilters: [String: CIFilter] = [:]
    private var lastInput: UIImage?
    private var lastSettings: Settings?
    private var lastCubeKeys: [String]?
    private var lastImage: UIImage?

    public init(beginReadback: @escaping () -> Void = {}, endReadback: @escaping () -> Void = {}) {
        self.beginReadback = beginReadback; self.endReadback = endReadback
        let space = Self.displaySpace
        outputColorSpace = space
        context = CIContext(options: [.workingFormat: CIFormat.BGRA8,
            .workingColorSpace: space, .cacheIntermediates: false])
    }

    public func evictRenderCache() {
        lastInput = nil; lastSettings = nil; lastCubeKeys = nil; lastImage = nil
    }

    public func render(_ image: UIImage, settings: Settings, identity: Bool,
        prepare: () -> MonitorUIImageGraph) -> UIImage {
        if identity { evictRenderCache(); return image }
        let graph = prepare()
        let cubeKeys = graph.look.cubeKeys
        // Stored cubes can change while the source image and selected filename stay the same.
        if image === lastInput, settings == lastSettings, cubeKeys == lastCubeKeys,
            let lastImage { return lastImage }
        guard let output = outputCIImage(for: image, graph: graph) else { return image }
        beginReadback()
        defer { endReadback() }
        guard let cgImage = context.createCGImage(output, from: output.extent,
                format: .BGRA8, colorSpace: outputColorSpace)
        else { return image }
        let rendered = UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
        lastInput = image; lastSettings = settings; lastCubeKeys = cubeKeys; lastImage = rendered
        return rendered
    }

    public func outputCIImage(for image: UIImage, graph: MonitorUIImageGraph) -> CIImage? {
        guard let input = CIImage(image: image, options: [.colorSpace: NSNull()]) else { return nil }
        let extent = input.extent
        let display = graph.smoothing.map {
            MonitorBlockArtifactCompositor.applyFlatSmoothing(to: input, settings: $0, extent: extent)
        } ?? input
        var output = display
        switch graph.look {
        case .plain: break
        case .grade(let cube, let split):
            output = splitting(applyCube(to: display, request: cube), over: display, extent: extent, vertical: split)
        case .replacement(let cube): output = applyCube(to: input, request: cube)
        case .limits(let grade, let split, let paint, let weight):
            if let grade {
                output = splitting(applyCube(to: display, request: grade), over: display, extent: extent, vertical: split)
            }
            let painted = applyCube(to: input, request: paint)
            let mask = applyCube(to: input, request: weight)
            output = painted.cropped(to: extent).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output.cropped(to: extent), kCIInputMaskImageKey: mask.cropped(to: extent)])
        }
        if let dither = graph.dither {
            output = MonitorBlockArtifactCompositor.applyDither(to: output, settings: dither, extent: extent)
        }
        if let peaking = graph.peaking {
            output = MonitorImageCompositor.applyPeaking(over: output, source: input, extent: extent,
                color: peaking.color, sense: peaking.sensitivity, gateScale: peaking.gateScale,
                fusedWindowPolicy: peaking.fusedWindowPolicy)
        }
        if let zebra = graph.zebra {
            output = MonitorImageCompositor.applyResolvedZebra(over: output, source: input, extent: extent, zebra: zebra)
        }
        return output
    }

    private func applyCube(to input: CIImage, request: MonitorNativeCubeRequest) -> CIImage {
        let filter: CIFilter?
        if let cached = cubeFilters[request.key] { filter = cached }
        else if let cube = request.resolve() {
            let built = CIFilter(name: "CIColorCube", parameters: [
                "inputCubeDimension": cube.dimension, "inputCubeData": cube.rgba])
            cubeFilters[request.key] = built; filter = built
        } else { filter = nil }
        guard let filter else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        return filter.outputImage ?? input
    }

    /// The graded half: the right half side by side, the bottom half top over bottom (Core Image y
    /// points up, so the bottom half is the low-y half), as `MonitorImageCompositor` splits.
    private func splitting(_ graded: CIImage, over source: CIImage, extent: CGRect, vertical: Bool?) -> CIImage {
        guard let vertical, extent.width > 0, extent.height > 0 else { return graded }
        let half = vertical
            ? CGRect(x: extent.midX, y: extent.minY, width: extent.width / 2, height: extent.height)
            : CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: extent.height / 2)
        return graded.cropped(to: half).composited(over: source.cropped(to: extent))
    }
}
#endif
