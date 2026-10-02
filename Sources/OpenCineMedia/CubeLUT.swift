import Foundation

/// A parsed Adobe/IRIDAS `.cube` 3D LUT.
///
/// Adapted from OpenZCine `CubeLUT` (Apache 2.0). `rgb` holds `size³` RGB triplets in
/// red-fastest order (`index = (r + g·size + b·size²) · 3`), each component in `[0, 1]`.
/// Turning the table into `CIColorCube` is the platform shell's job.
public struct CubeLUT: Equatable, Sendable {
    /// 2 is the minimum for trilinear interpolation. 65 is Resolve's default
    /// 3D size (many official camera cubes ship at 33, many vendor looks at 65).
    /// Hostile declarations still cap at 65 (~3.3 MB of floats).
    public static let supportedSizeRange = 2...65
    /// `CIColorCube` `inputCubeDimension` max. Larger tables downsample here.
    public static let colorCubeMaxDimension = 64

    public let size: Int
    public let rgb: [Float]

    public init(size: Int, rgb: [Float]) {
        self.size = size
        self.rgb = rgb
    }
}

public enum CubeLUTParseError: LocalizedError, Equatable {
    case missingSize
    case unsupportedSize(Int)
    case unsupportedDomain
    case sampleCountMismatch(expected: Int, found: Int)

    public var errorDescription: String? {
        switch self {
        case .missingSize:
            return "The .cube file is missing its LUT_3D_SIZE declaration."
        case .unsupportedSize(let size):
            return
                "The .cube file declares an unsupported LUT size of \(size). Supported sizes are "
                + "\(CubeLUT.supportedSizeRange.lowerBound)–\(CubeLUT.supportedSizeRange.upperBound)."
        case .unsupportedDomain:
            return
                "The .cube file declares a non-default input domain (DOMAIN_MIN/MAX); only the "
                + "standard 0–1 domain is supported."
        case .sampleCountMismatch(let expected, let found):
            return
                "The .cube file declares \(expected / 3) table entries but contains \(found / 3)."
        }
    }
}

extension CubeLUT {
    /// Parses a 3D `.cube`. Split on `isNewline` so CRLF-authored files (Windows LUT tools)
    /// are not rejected as a single comment line.
    public static func parse(_ text: String) throws -> CubeLUT {
        var size: Int?
        var values: [Float] = []

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("LUT_3D_SIZE") {
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if fields.count >= 2, let parsed = Int(fields[1]) {
                    guard CubeLUT.supportedSizeRange.contains(parsed) else {
                        throw CubeLUTParseError.unsupportedSize(parsed)
                    }
                    size = parsed
                }
                continue
            }

            if line.hasPrefix("DOMAIN_MIN") || line.hasPrefix("DOMAIN_MAX") {
                let expected: Float = line.hasPrefix("DOMAIN_MIN") ? 0 : 1
                let comps = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .dropFirst().compactMap { Float($0) }
                guard comps.count >= 3, comps.prefix(3).allSatisfy({ $0 == expected }) else {
                    throw CubeLUTParseError.unsupportedDomain
                }
                continue
            }

            guard let first = line.first else { continue }
            let startsData =
                ("0"..."9").contains(first) || first == "+" || first == "-"
                || first == "."
            if !startsData { continue }

            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3,
                let r = Float(fields[0]), let g = Float(fields[1]), let b = Float(fields[2])
            else { continue }
            values.append(r)
            values.append(g)
            values.append(b)
        }

        guard let resolvedSize = size else { throw CubeLUTParseError.missingSize }
        let expected = resolvedSize * resolvedSize * resolvedSize * 3
        guard values.count == expected else {
            throw CubeLUTParseError.sampleCountMismatch(expected: expected, found: values.count)
        }
        return CubeLUT(size: resolvedSize, rgb: values)
    }

    /// Table Core Image can load. 65³ Resolve cubes resample to 64³.
    public var colorCube: CubeLUT {
        size <= Self.colorCubeMaxDimension ? self : resampled(to: Self.colorCubeMaxDimension)
    }

    /// Trilinear resample onto an `n³` lattice. Used to fit Resolve 65³ into CI.
    public func resampled(to target: Int) -> CubeLUT {
        let n = max(2, target)
        if n == size { return self }
        let denom = Float(n - 1)
        var out = [Float]()
        out.reserveCapacity(n * n * n * 3)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let mapped = map(
                        red: Float(r) / denom, green: Float(g) / denom, blue: Float(b) / denom)
                    out.append(mapped.red)
                    out.append(mapped.green)
                    out.append(mapped.blue)
                }
            }
        }
        return CubeLUT(size: n, rgb: out)
    }

    /// RGBA float components (`size³ × 4`, red-fastest, alpha = 1) for `CIColorCube`.
    public var rgbaComponents: [Float] {
        var out = [Float]()
        out.reserveCapacity(size * size * size * 4)
        var index = 0
        while index + 2 < rgb.count {
            out.append(rgb[index])
            out.append(rgb[index + 1])
            out.append(rgb[index + 2])
            out.append(1)
            index += 3
        }
        return out
    }

    public func map(red: Float, green: Float, blue: Float) -> (
        red: Float, green: Float, blue: Float
    ) {
        let n = size
        guard n >= 2, rgb.count == n * n * n * 3 else { return (red, green, blue) }
        let scale = Float(n - 1)
        let fr = min(max(red, 0), 1) * scale
        let fg = min(max(green, 0), 1) * scale
        let fb = min(max(blue, 0), 1) * scale
        let r0 = Int(fr)
        let g0 = Int(fg)
        let b0 = Int(fb)
        let r1 = min(r0 + 1, n - 1)
        let g1 = min(g0 + 1, n - 1)
        let b1 = min(b0 + 1, n - 1)
        let tr = fr - Float(r0)
        let tg = fg - Float(g0)
        let tb = fb - Float(b0)

        func lattice(_ r: Int, _ g: Int, _ b: Int, _ channel: Int) -> Float {
            rgb[(r + g * n + b * n * n) * 3 + channel]
        }
        func sample(_ channel: Int) -> Float {
            let c00 = lattice(r0, g0, b0, channel) * (1 - tr) + lattice(r1, g0, b0, channel) * tr
            let c10 = lattice(r0, g1, b0, channel) * (1 - tr) + lattice(r1, g1, b0, channel) * tr
            let c01 = lattice(r0, g0, b1, channel) * (1 - tr) + lattice(r1, g0, b1, channel) * tr
            let c11 = lattice(r0, g1, b1, channel) * (1 - tr) + lattice(r1, g1, b1, channel) * tr
            let c0 = c00 * (1 - tg) + c10 * tg
            let c1 = c01 * (1 - tg) + c11 * tg
            return c0 * (1 - tb) + c1 * tb
        }
        return (sample(0), sample(1), sample(2))
    }
}

/// Generated monitor looks. Official camera Rec.709 cubes ship with each integration;
/// these remain small grading aids for tests and tools.
public enum BuiltInLook: String, CaseIterable, Sendable, Identifiable {
    case mono = "Mono"
    case contrast = "Contrast"
    case warm = "Warm"
    case cool = "Cool"

    public var id: String { rawValue }

    /// 17³ is enough for a smooth look and stays tiny in memory.
    public func cube(size: Int = 17) -> CubeLUT {
        let n = max(2, min(size, 64))
        let denom = Float(n - 1)
        var rgb = [Float]()
        rgb.reserveCapacity(n * n * n * 3)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let rf = Float(r) / denom
                    let gf = Float(g) / denom
                    let bf = Float(b) / denom
                    let mapped = map(red: rf, green: gf, blue: bf)
                    rgb.append(mapped.0)
                    rgb.append(mapped.1)
                    rgb.append(mapped.2)
                }
            }
        }
        return CubeLUT(size: n, rgb: rgb)
    }

    public func map(red: Float, green: Float, blue: Float) -> (Float, Float, Float) {
        switch self {
        case .mono:
            let y = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            return (y, y, y)
        case .contrast:
            func s(_ x: Float) -> Float {
                let t = min(max(x, 0), 1)
                return min(max(0.5 + 1.35 * (t - 0.5), 0), 1)
            }
            return (s(red), s(green), s(blue))
        case .warm:
            return (
                min(red * 1.08 + 0.04, 1),
                green,
                max(blue * 0.88 - 0.02, 0)
            )
        case .cool:
            return (
                max(red * 0.90 - 0.02, 0),
                green,
                min(blue * 1.10 + 0.03, 1)
            )
        }
    }
}
