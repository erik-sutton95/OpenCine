import Foundation

public enum ScopeChroma {
    public static func rec709(red: Double, green: Double, blue: Double) -> (cb: Double, cr: Double) {
        let y = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return ((blue - y) / 1.8556, (red - y) / 1.5748)
    }

    public static func rec709(red: UInt8, green: UInt8, blue: UInt8) -> (cb: Double, cr: Double) {
        rec709(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    /// Neutrals become white; saturated bins keep hue while the strongest
    /// channel rides full ramp brightness.
    public static func traceTint(
        red: Double, green: Double, blue: Double
    ) -> (red: Double, green: Double, blue: Double) {
        let low = min(red, green, blue)
        let high = max(red, green, blue)
        let span = high - low
        guard high > 0.000_001, span > 0.000_001 else {
            return (1, 1, 1)
        }
        let saturation = min(1, max(0, span / high))
        func tint(_ component: Double) -> Double {
            let pure = (component - low) / span
            return (1 - saturation) + pure * saturation
        }
        return (tint(red), tint(green), tint(blue))
    }
}

public enum VectorscopeRaster {

    public static let bins = 128

    /// Storage-row CbCr bin (row 0 = most negative Cr). Samples outside
    /// the plot after applying gain are dropped, rather than clamped.
    public static func binIndex(
        red: UInt8, green: UInt8, blue: UInt8, gain: Double = 1
    ) -> (column: Int, row: Int)? {
        let chroma = ScopeChroma.rec709(red: red, green: green, blue: blue)
        let x = chroma.cb * gain + 0.5
        let y = chroma.cr * gain + 0.5
        guard x >= 0, x <= 1, y >= 0, y <= 1 else { return nil }
        let scale = Double(bins - 1)
        return (Int((x * scale).rounded()), Int((y * scale).rounded()))
    }

    /// Premultiplied RGBA8 with logarithmic density alpha
    /// `(0.4 + 0.6·density) × intensity`, `traceTint` colour, +Cr flipped
    /// up. `nil` when nothing lands.
    public static func pixels(from points: [ScopePoint], gain: Double, intensity: Double) -> [UInt8]? {
        guard !points.isEmpty else { return nil }
        let n = bins
        var counts = [UInt32](repeating: 0, count: n * n)
        var sumRed = [UInt32](repeating: 0, count: n * n)
        var sumGreen = [UInt32](repeating: 0, count: n * n)
        var sumBlue = [UInt32](repeating: 0, count: n * n)
        for point in points {
            guard
                let bin = binIndex(
                    red: point.red, green: point.green, blue: point.blue, gain: gain)
            else { continue }
            let idx = bin.row * n + bin.column
            counts[idx] &+= 1
            sumRed[idx] &+= UInt32(point.red)
            sumGreen[idx] &+= UInt32(point.green)
            sumBlue[idx] &+= UInt32(point.blue)
        }
        let peak = counts.max() ?? 0
        guard peak > 0 else { return nil }
        let logPeak = log(1 + Double(peak))
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        for index in 0..<(n * n) where counts[index] > 0 {
            let count = Double(counts[index])
            let density = log(1 + count) / logPeak
            let alpha = min(1, max(0, (0.4 + 0.6 * density) * intensity))
            let tint = ScopeChroma.traceTint(
                red: Double(sumRed[index]) / (count * 255),
                green: Double(sumGreen[index]) / (count * 255),
                blue: Double(sumBlue[index]) / (count * 255))
            let row = n - 1 - index / n
            let column = index % n
            let offset = (row * n + column) * 4
            pixels[offset] = UInt8(255 * tint.red * alpha)
            pixels[offset + 1] = UInt8(255 * tint.green * alpha)
            pixels[offset + 2] = UInt8(255 * tint.blue * alpha)
            pixels[offset + 3] = UInt8(255 * alpha)
        }
        return pixels
    }
}
