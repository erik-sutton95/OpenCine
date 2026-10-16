import Foundation
import OpenCineCameraVocabulary

/// A movie tone mode (colour and gamma) a Nikon Z body records in.
public enum NikonMovieTone: String, CaseIterable, Hashable, Sendable {
    case sdr = "SDR"
    case hlg = "HLG"
    case nLog = "N-Log"
    /// R3D NE records RED Log3G10 only; it is the codec's tone, never a written value.
    case log3G10 = "Log3G10"

    public var label: String { rawValue }
}

/// Where a Z body keeps the movie tone for each recording codec, and which tones the body offers.
///
/// Newer Z bodies keep one tone property per codec family (libgphoto2 `ptp.h` names:
/// `MovieProResToneMode` 0x1D000, `MovieH265ToneMode` 0x1D001, `MovieNRaw12bitToneMode` 0x1D028,
/// `MovieProResRawHq12bitToneMode` 0x1D029). The offered tones are the property descriptor's
/// enumeration on the connected body, never a fixed list. A codec that records one tone only has
/// no tone property here and shows that tone fixed: R3D NE records Log3G10, and 8-bit codecs
/// (H.264, H.265 8-bit) record SDR.
///
/// Hardware record (ZR firmware 1.11, 2026-10-16, `evidence/.../codec-color/zr-probe-percodec.log`):
/// each tone property's enumeration is static and does not follow the selected codec (H.265
/// offers 0, 1, 2; ProRes 422 HQ, N-RAW and ProRes RAW offer 0, 1). With every tone property at 1,
/// `MovieLogOutput` (0xD0BB) reads 1 for H.265 10-bit, N-RAW, ProRes 422 HQ and ProRes RAW, and 0
/// for H.264, H.265 8-bit and R3D NE. So 1 is N-Log, and 8-bit H.265 records SDR whatever
/// 0x1D001 holds. 0x1D029 follows ProRes RAW, the libgphoto2 `MovieProResRawHq12bitToneMode` name.
public enum NikonMovieToneCapability {
    /// The codec byte of a packed `MovFileType` value (`0x00_CC_DD_KK`).
    static func codecByte(_ fileType: UInt32) -> UInt32 { (fileType >> 16) & 0xFF }

    /// The bit-depth byte of a packed `MovFileType` value.
    static func depthByte(_ fileType: UInt32) -> UInt32 { (fileType >> 8) & 0xFF }

    /// The per-codec tone property for a packed `MovFileType`, or nil when the codec has none
    /// (including a codec that records a fixed tone).
    public static func toneProperty(forFileType fileType: UInt32) -> PTPPropertyCode? {
        guard fixedTone(forFileType: fileType) == nil else { return nil }
        return switch codecByte(fileType) {
        case 0x01: .movieH265ToneMode
        case 0x10: .movieProResToneMode
        case 0x02: .movieNRawToneMode
        case 0x11: .movieProResRawToneMode
        default: nil
        }
    }

    /// Every per-codec tone property, in the order the monitor polls them.
    public static let toneProperties: [PTPPropertyCode] = [
        .movieH265ToneMode, .movieProResToneMode, .movieNRawToneMode, .movieProResRawToneMode,
    ]

    /// The tone a codec records without a choice: R3D NE is Log3G10 only, and an 8-bit codec
    /// records SDR only. Nil when the codec offers a tone choice.
    public static func fixedTone(forFileType fileType: UInt32) -> NikonMovieTone? {
        if codecByte(fileType) == 0x31 { return .log3G10 }
        if depthByte(fileType) == 0x08 { return .sdr }
        return nil
    }

    /// Movie tone property values (UINT8). 0 SDR and 2 HLG share the stills `ToneMode` encoding
    /// (its enumeration is 0, 2 on the ZR); 1 N-Log is proven by `MovieLogOutput` (see above).
    static let toneByRaw: [UInt32: NikonMovieTone] = [0: .sdr, 1: .nLog, 2: .hlg]

    /// The tone a raw property value names, or nil for an unknown value.
    public static func tone(raw: UInt32) -> NikonMovieTone? { toneByRaw[raw] }

    /// The raw value for a writable tone, or nil (Log3G10 is never written).
    public static func raw(for tone: NikonMovieTone) -> UInt8? {
        toneByRaw.first { $0.value == tone }.map { UInt8($0.key) }
    }

    /// The tones a descriptor enumeration offers, in the camera menu's order (SDR, HLG, N-Log),
    /// not the enumeration's. Unknown values are dropped: we cannot name them, so we must not
    /// offer to write them.
    public static func tones(fromEnum values: [UInt32]) -> [NikonMovieTone] {
        let offered = Set(values.compactMap(tone(raw:)))
        return NikonMovieTone.allCases.filter(offered.contains)
    }

    /// Decodes a tone property readback (UINT8). Malformed or unknown is nil, never SDR.
    public static func tone(readback bytes: [UInt8]) -> NikonMovieTone? {
        bytes.count == 1 ? tone(raw: UInt32(bytes[0])) : nil
    }

    /// The write that selects `tone` for the codec `fileType` records in, or nil when that codec
    /// has no tone property or the tone has no value.
    public static func write(_ tone: NikonMovieTone, forFileType fileType: UInt32) -> PTPCameraPropertyWrite? {
        guard let property = toneProperty(forFileType: fileType), let raw = raw(for: tone) else { return nil }
        return PTPCameraPropertyWrite(property: property, data: Data([raw]))
    }

    /// The codec and colour popup for a Z body: the advertised codecs, and the tones the body
    /// offers for the selected codec (or the codec's fixed tone, shown and not editable).
    public static func codecColorChoices(
        codecs: [PTPCameraFileTypeMode], fileType: UInt32?,
        offered: [NikonMovieTone], current: NikonMovieTone?
    ) -> CaptureCodecColorChoices {
        let codecChoices = codecs.map { CaptureCodecColorChoice(id: String($0.raw), label: $0.label) }
        guard let fileType else {
            return CaptureCodecColorChoices(codecs: codecChoices)
        }
        let colors: [CaptureCodecColorChoice]
        let selected: NikonMovieTone?
        if let fixed = fixedTone(forFileType: fileType) {
            colors = [CaptureCodecColorChoice(id: fixed.rawValue, label: fixed.label, isEditable: false)]
            selected = fixed
        } else if toneProperty(forFileType: fileType) != nil {
            colors = offered.map { CaptureCodecColorChoice(id: $0.rawValue, label: $0.label, isEditable: offered.count > 1) }
            selected = current
        } else {
            colors = []
            selected = nil
        }
        return CaptureCodecColorChoices(
            codecs: codecChoices, selectedCodec: String(fileType),
            colors: colors, selectedColor: selected?.rawValue)
    }
}

extension PTPCameraPropertySnapshot {
    /// The tone the codec `fileType` records in: the reported value of its tone property, or the
    /// codec's fixed tone. Nil while unknown.
    public func movieTone(forFileType fileType: UInt32) -> NikonMovieTone? {
        if let fixed = NikonMovieToneCapability.fixedTone(forFileType: fileType) { return fixed }
        return NikonMovieToneCapability.toneProperty(forFileType: fileType).flatMap { movieTones[$0] }
    }
}
