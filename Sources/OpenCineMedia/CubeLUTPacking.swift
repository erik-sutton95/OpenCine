import Foundation

extension CubeLUT {
    /// RGBA8 grid: pixel `(x = b * size + r, y = g)`, alpha 255.
    /// Convert to Float before quantization, matching native cube consumers.
    public var packedRGBA: [UInt8] {
        let size = self.size
        var out = [UInt8](repeating: 255, count: size * size * size * 4)
        for g in 0..<size {
            for b in 0..<size {
                for r in 0..<size {
                    let src = (r + g * size + b * size * size) * 3
                    let dst = (g * size * size + b * size + r) * 4
                    out[dst] = Self.quantizedRGBAChannel(rgb[src])
                    out[dst + 1] = Self.quantizedRGBAChannel(rgb[src + 1])
                    out[dst + 2] = Self.quantizedRGBAChannel(rgb[src + 2])
                }
            }
        }
        return out
    }

    public static func quantizedRGBAChannel(_ value: Float) -> UInt8 {
        UInt8((min(max(value, 0), 1) * 255).rounded())
    }
}
