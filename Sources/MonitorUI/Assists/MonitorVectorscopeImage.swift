#if os(iOS)
import OpenCineMedia
import CoreGraphics
import Foundation

extension VectorscopeRaster {
    public static func image(from points: [ScopePoint], gain: Double, intensity: Double) -> CGImage? {
        guard let pixels = pixels(from: points, gain: gain, intensity: intensity) else {
            return nil
        }
        let n = bins
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
#endif
