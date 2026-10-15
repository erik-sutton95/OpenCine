import OpenCineMedia
import Testing

@Suite struct MonitorLogDisplayTransformTests {
    private let identity: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]

    @Test func anchorsGrayAndCopiesTheSourceMatrix() {
        var matrix = identity
        let transform = MonitorLogDisplayTransform(decode: { $0 }, sourceToRec709: matrix)
        matrix[0] = 0
        let output = transform.map(red: 0.18, green: 0.18, blue: 0.18)
        #expect(abs(output.red - 0.42) < 0.000001)
        #expect(output.red == output.green && output.green == output.blue)
    }

    @Test func rotatesNegativeDecodedChannelsBeforeClamping() {
        let transform = MonitorLogDisplayTransform(
            decode: { $0 - 0.25 }, sourceToRec709: [-1, 1, 0, 0, 1, 0, 0, 0, 1])
        let output = transform.map(red: 0, green: 0.5, blue: 0.25)
        let tone = MonitorSceneToneMap(sceneWhite: 0.75)
        #expect(output.red == Float(tone.displayCode(sceneLinear: 0.5)))
        #expect(output.green == Float(tone.displayCode(sceneLinear: 0.25)))
        #expect(output.blue == 0)
    }

    @Test func gridIsRedFastestAndRetainsLargerPublicDimensions() {
        let transform = MonitorLogDisplayTransform(decode: { $0 }, sourceToRec709: identity)
        let rgb = transform.rgb(size: 2)
        #expect(rgb.count == 24)
        #expect(Array(rgb[0..<3]) == [0, 0, 0])
        #expect(Array(rgb[3..<6]) == [1, 0, 0])
        #expect(Array(rgb[6..<9]) == [0, 1, 0])
        #expect(Array(rgb[12..<15]) == [0, 0, 1])
        #expect(transform.rgb(size: 65).count == 65 * 65 * 65 * 3)
    }

    @Test func neutralReadingInterpolatesTheCubeInsteadOfTheAnalyticTransform() {
        let transform = MonitorLogDisplayTransform(
            decode: { $0 * $0 * $0 * $0 }, sourceToRec709: identity)
        let curve = transform.neutralLumaCurve(cubeSize: 2, sampleCount: 3)
        #expect(curve.count == 3)
        #expect(abs(curve[1] - 0.5) < 0.000000000001)
        #expect(abs(Double(transform.map(red: 0.5, green: 0.5, blue: 0.5).red) - curve[1]) > 0.01)
    }
}
