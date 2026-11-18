import Foundation
import Testing

@testable import OpenCineStreaming

@Suite struct StreamMediaPacketTests {
    @Test func avcConfigRecordIsExact() {
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1F, 0xAC]
        let pps: [UInt8] = [0x68, 0xEE]
        #expect(
            FLVPayload.videoConfig(sps: sps, pps: pps)
                == [0x17, 0x00, 0, 0, 0] + [0x01, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0x00, 0x05] + sps
                + [0x01, 0x00, 0x02] + pps)
    }

    @Test func configWithoutAUsableSPSIsNil() {
        #expect(FLVPayload.videoConfig(sps: [0x67, 0x64], pps: [0x68]) == nil)
        #expect(FLVPayload.videoConfig(sps: [0x67, 0x64, 0x00, 0x1F], pps: []) == nil)
    }

    @Test func convertsThreeAndFourByteStartCodesToLengthPrefix() {
        let annexB: [UInt8] = [0, 0, 0, 1, 0x65, 0xAA, 0, 0, 1, 0x41, 0xBB]
        #expect(
            FLVPayload.video(annexB: annexB, isKeyframe: true, compositionMs: 33)
                == [0x17, 0x01, 0x00, 0x00, 0x21] + [0, 0, 0, 2, 0x65, 0xAA] + [0, 0, 0, 2, 0x41, 0xBB])
    }

    @Test func keepsInParameterSetsAndZerosInsideUnits() {
        let annexB: [UInt8] = [0, 0, 1, 0x67, 0x64, 0, 0, 0, 1, 0x68, 0xEE, 0, 0, 1, 0x65, 0x00, 0x00, 0x03, 0x01]
        #expect(
            FLVPayload.video(annexB: annexB, isKeyframe: true, compositionMs: 0)
                == [0x17, 0x01, 0, 0, 0] + [0, 0, 0, 2, 0x67, 0x64] + [0, 0, 0, 2, 0x68, 0xEE]
                + [0, 0, 0, 5, 0x65, 0x00, 0x00, 0x03, 0x01])
    }

    @Test func interframeUsesFrameType2() {
        #expect(FLVPayload.video(annexB: [0, 0, 1, 0x41, 1], isKeyframe: false, compositionMs: 0)?.first == 0x27)
    }

    @Test func negativeCompositionIsSigned24Bit() {
        let tag = FLVPayload.video(annexB: [0, 0, 1, 0x41, 1], isKeyframe: false, compositionMs: -2)
        #expect(tag.map { Array($0[2..<5]) } == [0xFF, 0xFF, 0xFE])
    }

    @Test(arguments: [[UInt8](), [0, 0, 0, 1], [0, 0, 1, 0, 0, 1], [0x41, 0x01]])
    func emptyAnnexBIsNil(annexB: [UInt8]) {
        #expect(FLVPayload.video(annexB: annexB, isKeyframe: true, compositionMs: 0) == nil)
    }

    @Test func audioTagsAreExact() {
        #expect(FLVPayload.audioConfig([0x11, 0x90]) == [0xAF, 0x00, 0x11, 0x90])
        #expect(FLVPayload.audio([1, 2]) == [0xAF, 0x01, 1, 2])
    }
}
