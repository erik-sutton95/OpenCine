#if canImport(Metal)
import Foundation
import Metal
#if canImport(MetalFX)
import MetalFX
#endif
#if os(iOS) && !targetEnvironment(simulator)
import VideoToolbox
#endif

/// Which upscaler carries the bake→drawable blow-up. Raw values are the segment titles.
public enum MonitorUpscaler: String, CaseIterable, Sendable {
    /// Plain bilinear sample  -  the reference the rest are judged against.
    case off = "Off"
    /// MPS Lanczos. Every device can run this.
    case lanczos = "Fast"
    /// MetalFX Spatial, the FSR1-class edge-aware upscaler. A13+.
    case spatial = "Quality"
    /// VideoToolbox low-latency super-resolution. Infers detail the camera never captured.
    case superResolution = "AI"

    public var isSupportedOnThisDevice: Bool {
        switch self {
        case .off, .lanczos: true
        case .spatial: Self.spatialSupported
        case .superResolution: Self.superResolutionSupported
        }
    }

    public static var supportedOnThisDevice: [MonitorUpscaler] { allCases.filter(\.isSupportedOnThisDevice) }

    /// `candidate` when this device can run it, otherwise the Fast floor.
    public static func supported(or candidate: MonitorUpscaler?) -> MonitorUpscaler {
        if let candidate, candidate.isSupportedOnThisDevice { return candidate }
        return .lanczos
    }

    private static let spatialSupported: Bool = {
        #if canImport(MetalFX)
            guard let device = MTLCreateSystemDefaultDevice() else { return false }
            return MTLFXSpatialScalerDescriptor.supportsDevice(device)
        #else
            return false
        #endif
    }()

    private static let superResolutionSupported: Bool = {
        #if !os(iOS) || targetEnvironment(simulator)
            return false
        #else
            guard #available(iOS 26.0, *) else { return false }
            return VTLowLatencySuperResolutionScalerConfiguration.isSupported
        #endif
    }()

    public static func superResolutionInputSize(
        source: (width: Int, height: Int),
        target: (width: Int, height: Int),
        scale: Float,
        maximum: (width: Int, height: Int)
    ) -> (width: Int, height: Int) {
        guard source.width > 0, source.height > 0, maximum.width > 0, maximum.height > 0
        else { return source }
        var shrink = min(
            Double(maximum.width) / Double(source.width),
            Double(maximum.height) / Double(source.height),
            1)
        if scale > 0 {
            let clears = max(
                Double(target.width) / (Double(source.width) * Double(scale)),
                Double(target.height) / (Double(source.height) * Double(scale)))
            if clears < 1 { shrink = min(shrink, clears) }
        }
        guard shrink < 1 else { return source }
        return (
            max(1, Int((Double(source.width) * shrink).rounded(.down))),
            max(1, Int((Double(source.height) * shrink).rounded(.down)))
        )
    }

    public static func superResolutionScale(offered: [Float], ratio: Double, held: Float? = nil) -> Float?
    {
        if let held, Double(held) >= ratio { return held }
        let ordered = offered.sorted()
        return ordered.first { Double($0) >= ratio } ?? ordered.last
    }
}
#endif
