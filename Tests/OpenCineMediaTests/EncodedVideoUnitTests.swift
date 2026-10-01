import OpenCineCore
import Testing

@testable import OpenCineMedia

@Suite struct EncodedVideoUnitTests {
    private let sc: [UInt8] = [0, 0, 1]
    private let stream = StreamID()
    private let generation = StreamGeneration(3)

    @Test func hevcKeyframeCarriesItsParameterSets() {
        let vps: [UInt8] = [0x40, 0x01, 0x0C]
        let sps: [UInt8] = [0x42, 0x01, 0x01]
        let pps: [UInt8] = [0x44, 0x01, 0xC1]
        let idr: [UInt8] = [0x28, 0x01, 0xAA]  // IDR_N_LP
        let au: [UInt8] = [sc, vps, sc, sps, sc, pps, sc, idr].flatMap { $0 }
        let unit = EncodedVideoUnit(
            stream: stream, generation: generation, annexB: au, codec: .hevc,
            previousParameterSets: [[0x40, 0x09]], hostArrival: 10)
        #expect(unit.codec == EncodedVideoUnit.Codec.hevc && unit.isRandomAccess)
        #expect(unit.parameterSets == [vps, sps, pps])
        #expect(unit.payload == au && unit.generation == generation && unit.stream == stream)
        #expect(unit.presentationTime == nil && unit.format == nil)

        // A P-slice joins mid-GOP: not random access, decodes against the stream's sets.
        let p = EncodedVideoUnit(
            stream: stream, generation: generation, annexB: sc + [0x02, 0x01, 0xBB], codec: .hevc,
            previousParameterSets: unit.parameterSets, hostArrival: 10.04, presentationTime: 1.5)
        #expect(!p.isRandomAccess && p.parameterSets == [vps, sps, pps])
        #expect(p.presentationTime == 1.5)
    }

    @Test func avcUsesAvcNalTypes() {
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1F]
        let pps: [UInt8] = [0x68, 0xEE, 0x06]
        let idr: [UInt8] = [0x65, 0x88]
        let au: [UInt8] = [sc, sps, sc, pps, sc, idr].flatMap { $0 }
        let unit = EncodedVideoUnit(
            stream: stream, generation: generation, annexB: au, codec: .avc,
            previousParameterSets: [], hostArrival: 0)
        #expect(unit.codec == EncodedVideoUnit.Codec.avc && unit.isRandomAccess)
        #expect(unit.parameterSets == [sps, pps])
        // 0x41 is an AVC P-slice, not an HEVC VPS.
        let p = EncodedVideoUnit(
            stream: stream, generation: generation, annexB: sc + [0x41, 0x9A], codec: .avc,
            previousParameterSets: unit.parameterSets, hostArrival: 0)
        #expect(!p.isRandomAccess && p.parameterSets == [sps, pps])
    }

    @Test func jpegIsSelfContained() throws {
        let unit = EncodedVideoUnit(
            stream: stream, generation: generation, codec: .jpeg, payload: [0xFF, 0xD8, 0xFF, 0xD9],
            isRandomAccess: true, parameterSets: [], hostArrival: 2,
            format: .init(width: 1024, height: 576))
        #expect(unit.isRandomAccess && unit.parameterSets.isEmpty)
        let size = try #require(unit.format).uprightSize
        #expect(size == (1024, 576))
    }

    @Test func uprightSizeSwapsOnQuarterTurns() {
        let format = EncodedVideoUnit.Format(width: 1280, height: 720, rotation: .clockwise90)
        #expect(format.uprightSize == (720, 1280))
        #expect(EncodedVideoUnit.Format(width: 1280, height: 720, rotation: .upsideDown).uprightSize == (1280, 720))
        #expect(!format.mirrored)
    }
}
