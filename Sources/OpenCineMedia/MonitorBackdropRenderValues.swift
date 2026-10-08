import Foundation

/// One native blur product. Several presentation roles can share the same pixels.
public struct MonitorBackdropBlurProduct: Hashable, Sendable {
    public let radius: Double
    public let saturation: Double
    public init(radius: Double, saturation: Double) {
        self.radius = radius
        self.saturation = saturation
    }
}

public struct MonitorBackdropRasterSize: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let scale: Double
}

/// Bounded native raster facts, independent of camera and presentation roles.
public enum MonitorBackdropRenderValues {
    public static let maximumDimension = 320
    public static let minimumInterval: Double = 1.0 / 60.0
    public static let minimumIntervalNanoseconds: UInt64 = 16_666_667

    public static func rasterSize(width: Double, height: Double) -> MonitorBackdropRasterSize? {
        guard width.isFinite, height.isFinite, width > 1, height > 1 else { return nil }
        let scale = min(1, Double(maximumDimension) / max(width, height))
        return MonitorBackdropRasterSize(width: Int(ceil(width * scale)),
            height: Int(ceil(height * scale)), scale: scale)
    }

    public static func distinctProducts(_ products: [MonitorBackdropBlurProduct])
        -> [MonitorBackdropBlurProduct] {
        products.reduce(into: []) { result, product in
            if !result.contains(product) { result.append(product) }
        }
    }
}

/// The extra source facts read by FALSE and ZEBRA outside the stored effect values.
/// Absent map clipping means that the requested map is not ready yet.
public struct MonitorBackdropLookState: Equatable, Sendable {
    public let clipByte: Int
    public let mapClipByte: Int?
    public init(clipByte: Int, mapClipByte: Int?) {
        self.clipByte = clipByte
        self.mapClipByte = mapClipByte
    }
}
