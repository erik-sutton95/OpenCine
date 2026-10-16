import Foundation

/// A generated display look: raw source decoding, a source-owned Float gamut matrix, and the
/// shared scene tone map. The decoder must be pure; negative decoded channels reach the matrix
/// before output channels clamp, preserving the source transform's calibrated arithmetic.
public struct MonitorLogDisplayTransform: Sendable {
    private let decode: @Sendable (Double) -> Double
    private let sourceToRec709: [Float]

    /// The row-major matrix belongs to the source integration and must contain nine entries.
    public init(
        decode: @escaping @Sendable (Double) -> Double, sourceToRec709: [Float]
    ) {
        precondition(sourceToRec709.count == 9)
        self.decode = decode
        self.sourceToRec709 = sourceToRec709
    }

    /// Applies the source transform without clamping its raw decoded channels prematurely.
    public func map(red: Float, green: Float, blue: Float) -> (
        red: Float, green: Float, blue: Float
    ) {
        let lr = Float(decode(Double(red)))
        let lg = Float(decode(Double(green)))
        let lb = Float(decode(Double(blue)))
        let m = sourceToRec709
        let outR = max(0, m[0] * lr + m[1] * lg + m[2] * lb)
        let outG = max(0, m[3] * lr + m[4] * lg + m[5] * lb)
        let outB = max(0, m[6] * lr + m[7] * lg + m[8] * lb)
        let tone = MonitorSceneToneMap(sceneWhite: Double(Float(decode(1.0))))
        return (
            Float(tone.displayCode(sceneLinear: Double(outR))),
            Float(tone.displayCode(sceneLinear: Double(outG))),
            Float(tone.displayCode(sceneLinear: Double(outB)))
        )
    }

    /// Samples a red-fastest Float RGB lattice, retaining the caller's requested dimension.
    public func rgb(size: Int = 33) -> [Float] {
        precondition(size >= 2)
        let denominator = Float(size - 1)
        var result: [Float] = []
        result.reserveCapacity(size * size * size * 3)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let mapped = map(
                        red: Float(r) / denominator, green: Float(g) / denominator,
                        blue: Float(b) / denominator)
                    result.append(mapped.red)
                    result.append(mapped.green)
                    result.append(mapped.blue)
                }
            }
        }
        return result
    }

    /// Reads display luminance through the sampled look, including its Float interpolation.
    /// Direct analytic sampling would differ from the monitor's cube between lattice points.
    public func neutralLumaCurve(cubeSize: Int = 33, sampleCount: Int = 256) -> [Double] {
        precondition(sampleCount >= 2)
        let cube = CubeLUT(size: cubeSize, rgb: rgb(size: cubeSize))
        return (0..<sampleCount).map { index in
            let code = Float(index) / Float(sampleCount - 1)
            let mapped = cube.map(red: code, green: code, blue: code)
            return 0.2126 * Double(mapped.red) + 0.7152 * Double(mapped.green)
                + 0.0722 * Double(mapped.blue)
        }
    }
}
