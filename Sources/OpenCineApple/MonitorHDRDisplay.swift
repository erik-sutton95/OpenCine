#if canImport(UIKit) && canImport(Metal)
import CoreGraphics
import Metal
import QuartzCore
import UIKit

/// Native layer configuration from explicit effective display demand.
public enum MonitorHDRDisplay {
    public static func configure(_ layer: CAMetalLayer, enabled: Bool) {
        let format: MTLPixelFormat = enabled ? .rgba16Float : .bgra8Unorm
        if layer.pixelFormat != format { layer.pixelFormat = format }
        if layer.wantsExtendedDynamicRangeContent != enabled {
            layer.wantsExtendedDynamicRangeContent = enabled
        }
        let name = enabled ? CGColorSpace.extendedLinearDisplayP3 : nil
        if layer.colorspace?.name != name {
            layer.colorspace = name.flatMap { CGColorSpace(name: $0) }
        }
        if #available(iOS 26.0, *) {
            let range: CALayer.DynamicRange = enabled ? .high : .automatic
            if layer.preferredDynamicRange != range { layer.preferredDynamicRange = range }
        }
    }
}
#endif
