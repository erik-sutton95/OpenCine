import Foundation
import OpenCineCameraVocabulary
import Testing

@testable import OpenCineNikon

/// Movie tone per codec on Z bodies: the property each codec family keeps, the tones the body's
/// descriptor offers, the codec's fixed tone, and the one codec and colour popup built from them.
@Suite struct NikonMovieToneTests {
    // Packed MovFileType values as the body advertises them (codec, depth, container).
    let h265_10 = UInt32(0x0001_0A00)
    let h265_8 = UInt32(0x0001_0800)
    let h264_8 = UInt32(0x0000_0800)
    let prores = UInt32(0x0010_0A00)
    let nraw = UInt32(0x0002_0C02)
    let proresRaw = UInt32(0x0011_0C00)
    let r3d = UInt32(0x0031_0C03)

    @Test func eachCodecFamilyKeepsItsOwnToneProperty() {
        #expect(NikonMovieToneCapability.toneProperty(forFileType: h265_10) == .movieH265ToneMode)
        #expect(NikonMovieToneCapability.toneProperty(forFileType: prores) == .movieProResToneMode)
        #expect(NikonMovieToneCapability.toneProperty(forFileType: nraw) == .movieNRawToneMode)
        #expect(NikonMovieToneCapability.toneProperty(forFileType: proresRaw) == .movieProResRawToneMode)
        #expect(NikonMovieToneCapability.toneProperty(forFileType: r3d) == nil)
        #expect(NikonMovieToneCapability.toneProperty(forFileType: h264_8) == nil)
        #expect(NikonMovieToneCapability.toneProperty(forFileType: h265_8) == nil, "8-bit H.265 is SDR only")
        #expect(PTPPropertyCode.movieH265ToneMode.rawValue == 0x0001_D001)
        #expect(PTPPropertyCode.movieProResToneMode.rawValue == 0x0001_D000)
        #expect(PTPPropertyCode.movieNRawToneMode.rawValue == 0x0001_D028)
        #expect(PTPPropertyCode.movieProResRawToneMode.rawValue == 0x0001_D029)
    }

    @Test func r3dRecordsLog3G10OnlyAndItIsNeverWritten() {
        #expect(NikonMovieToneCapability.fixedTone(forFileType: r3d) == .log3G10)
        #expect(NikonMovieToneCapability.fixedTone(forFileType: h265_10) == nil)
        #expect(NikonMovieToneCapability.write(.log3G10, forFileType: r3d) == nil)
        #expect(NikonMovieToneCapability.raw(for: .log3G10) == nil)
    }

    @Test func eightBitCodecsRecordSDROnlyAndAreNeverWritten() {
        // ZR 1.11: MovieLogOutput reads 0 for H.264 and H.265 8-bit with 0x1D001 at N-Log.
        #expect(NikonMovieToneCapability.fixedTone(forFileType: h264_8) == .sdr)
        #expect(NikonMovieToneCapability.fixedTone(forFileType: h265_8) == .sdr)
        #expect(NikonMovieToneCapability.write(.nLog, forFileType: h265_8) == nil)
        var snapshot = PTPCameraPropertySnapshot()
        snapshot = snapshot.applying(property: .movieH265ToneMode, data: Data([1]))
        #expect(snapshot.movieTone(forFileType: h265_10) == .nLog)
        #expect(snapshot.movieTone(forFileType: h265_8) == .sdr)
    }

    @Test func toneValuesDecodeAndUnknownIsNeverSDR() {
        #expect(NikonMovieToneCapability.tone(readback: [0]) == .sdr)
        #expect(NikonMovieToneCapability.tone(readback: [1]) == .nLog)
        #expect(NikonMovieToneCapability.tone(readback: [2]) == .hlg)
        #expect(NikonMovieToneCapability.tone(readback: [9]) == nil)
        #expect(NikonMovieToneCapability.tone(readback: []) == nil)
        #expect(NikonMovieToneCapability.tone(readback: [0, 0]) == nil)
    }

    @Test func offeredTonesAreTheDescriptorsInTheCameraMenuOrder() {
        // The ZR enumerates 0x1D001 as 0, 1, 2 (SDR, N-Log, HLG); its menu reads SDR, HLG, N-Log.
        #expect(NikonMovieToneCapability.tones(fromEnum: [0, 1, 2]) == [.sdr, .hlg, .nLog])
        #expect(NikonMovieToneCapability.tones(fromEnum: [1, 0]) == [.sdr, .nLog])
        #expect(NikonMovieToneCapability.tones(fromEnum: [1]) == [.nLog])
        #expect(NikonMovieToneCapability.tones(fromEnum: [0, 7, 0]) == [.sdr], "unknown dropped, repeat kept once")
    }

    @Test func aToneWriteTargetsTheActiveCodecsProperty() {
        let write = NikonMovieToneCapability.write(.nLog, forFileType: prores)
        #expect(write?.property == .movieProResToneMode)
        #expect(write?.data == Data([1]))
        #expect(NikonMovieToneCapability.write(.hlg, forFileType: h265_10)?.property == .movieH265ToneMode)
        #expect(NikonMovieToneCapability.write(.sdr, forFileType: h264_8) == nil)
    }

    @Test func theSnapshotKeepsEachCodecsToneApart() {
        var snapshot = PTPCameraPropertySnapshot()
        snapshot = snapshot.applying(property: .movieH265ToneMode, data: Data([1]))
        snapshot = snapshot.applying(property: .movieProResToneMode, data: Data([2]))
        #expect(snapshot.movieTone(forFileType: h265_10) == .nLog)
        #expect(snapshot.movieTone(forFileType: prores) == .hlg)
        #expect(snapshot.movieTone(forFileType: nraw) == nil, "never read is unknown")
        #expect(snapshot.movieTone(forFileType: r3d) == .log3G10)
        // An unknown readback retires the older tone instead of keeping or inventing one.
        snapshot = snapshot.applying(property: .movieH265ToneMode, data: Data([9]))
        #expect(snapshot.movieTone(forFileType: h265_10) == nil)
        #expect(snapshot.movieTone(forFileType: prores) == .hlg)
    }

    @Test func theMonitorPollsTheToneProperties() {
        for property in NikonMovieToneCapability.toneProperties {
            #expect(PTPPropertyCode.liveMonitorPollOrder.contains(property))
        }
        #expect(!PTPPropertyCode.recordingMonitorPollOrder.contains(.movieH265ToneMode))
    }

    private var codecs: [PTPCameraFileTypeMode] {
        PTPCameraPropertyDecoders.fileTypeModes(fromEnum: [r3d, nraw, proresRaw, prores, h265_10, h265_8, h264_8])
    }

    @Test func thePopupListsTheCodecsAndTheTonesOfTheSelectedCodec() {
        let choices = NikonMovieToneCapability.codecColorChoices(
            codecs: codecs, fileType: h265_10, offered: [.sdr, .hlg, .nLog], current: .nLog)
        #expect(choices.sections == [.codec, .color])
        #expect(choices.title == "CODEC · COLOR")
        #expect(choices.codecs.count == 7)
        #expect(choices.selectedCodec == String(h265_10))
        #expect(choices.colors.map(\.label) == ["SDR", "HLG", "N-Log"])
        #expect(choices.selectedColor == "N-Log")
        #expect(choices.colorEditable)
    }

    @Test func r3dShowsLog3G10FixedAndNotEditable() {
        let choices = NikonMovieToneCapability.codecColorChoices(
            codecs: codecs, fileType: r3d, offered: [.sdr, .hlg, .nLog], current: .sdr)
        #expect(choices.colors.map(\.label) == ["Log3G10"])
        #expect(choices.selectedColor == "Log3G10")
        #expect(!choices.colorEditable)
    }

    @Test func aSingleOfferedToneIsShownButNotAChoice() {
        let choices = NikonMovieToneCapability.codecColorChoices(
            codecs: codecs, fileType: nraw, offered: [.nLog], current: .nLog)
        #expect(choices.colors.map(\.label) == ["N-Log"])
        #expect(!choices.colorEditable)
    }

    @Test func anEightBitCodecShowsSDRFixedAndUnknownCodecShowsNoColour() {
        let h264 = NikonMovieToneCapability.codecColorChoices(
            codecs: codecs, fileType: h264_8, offered: [], current: nil)
        #expect(h264.sections == [.codec, .color])
        #expect(h264.colors.map(\.label) == ["SDR"])
        #expect(h264.selectedColor == "SDR")
        #expect(!h264.colorEditable)
        let h265 = NikonMovieToneCapability.codecColorChoices(
            codecs: codecs, fileType: h265_8, offered: [.sdr, .hlg, .nLog], current: .nLog)
        #expect(h265.colors.map(\.label) == ["SDR"])
        #expect(!h265.colorEditable)
        let unknown = NikonMovieToneCapability.codecColorChoices(
            codecs: codecs, fileType: nil, offered: [.sdr], current: .sdr)
        #expect(unknown.sections == [.codec])
        #expect(unknown.selectedCodec == nil)
    }
}
