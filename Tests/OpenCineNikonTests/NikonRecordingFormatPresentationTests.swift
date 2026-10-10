import Testing
@testable import OpenCineNikon

@Suite struct NikonRecordingFormatPresentationTests {
    private func mode(width: Int, height: Int, fps: Int, label: String) -> PTPCameraScreenSizeMode {
        PTPCameraScreenSizeMode(raw: UInt64(width) << 48 | UInt64(height) << 32 | UInt64(fps) << 16, label: label)
    }

    @Test func groupingRetainsTheExactCropAwareWriteToken() {
        let modes = [mode(width: 4032, height: 2268, fps: 25, label: "4K · 25p"), mode(width: 3984, height: 2240, fps: 25, label: "4K · 25p")]
        let presented = modes.map { NikonRecordingFormatPresentation(mode: $0, currentCodec: "R3D NE", isNikonZR: true) }
        #expect(presented.map(\.imageArea) == ["FX", "DX"])
        #expect(presented.map(\.resolution) == ["4K", "4K"])
        #expect(presented.map(\.frameRate) == ["25p", "25p"])
        let picked = NikonZRRawCropPresentation.pickedModeIndex(for: presented[1].token,
            presentationLabels: presented.map(\.token), modeLabels: modes.map(\.label))
        #expect(picked == 1)
        #expect(picked.map { modes[$0].raw } == modes[1].raw)
        #expect(NikonZRRawCropPresentation.pickedModeIndex(for: presented[1].token,
            presentationLabels: [presented[0].token], modeLabels: [modes[0].label]) == nil)
    }

    @Test func unrecognizedCropAndUnsupportedCodecNeverAcquireAnArea() {
        let known = mode(width: 4032, height: 2268, fps: 25, label: "4K · 25p")
        let unknown = mode(width: 3840, height: 2160, fps: 25, label: "4K · 25p")
        #expect(NikonRecordingFormatPresentation(mode: known, currentCodec: "H.265", isNikonZR: true).imageArea == nil)
        #expect(NikonRecordingFormatPresentation(mode: unknown, currentCodec: "R3D NE", isNikonZR: true).imageArea == nil)
        #expect(NikonRecordingFormatPresentation(mode: known, currentCodec: "R3D NE", isNikonZR: false).imageArea == nil)
    }
}
