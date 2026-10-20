import Foundation
import OpenCineCore

/// Hardware-qualified catalogue policy. Common controls consume only the resulting values.
public enum DJICaptureCapabilityProfile {
    public static func make(for model: CameraModel) -> CameraCaptureProfile {
        let compact = model.name.lowercased().replacingOccurrences(of: " ", with: "")
        let pro = compact.contains("pocket4p") || compact.contains("4pro")
        let pocket = model.family == .pocket
        var labels = CameraLabelProfile(colorModes: ColorMode.catalogueModes(for: model))
        if pocket { labels.colorModeLabels[.dLogM] = "D-Log M" }
        if model.isPocket3 { labels.shootingModeLabels[.superNight] = "Low-Light" }
        if model.family == .nano {
            labels.colorModeLabels[.normal] = "Normal 8-bit"
            labels.colorModeLabels[.dLogM] = "D-Log M 10-bit"
        }
        var formats: [ShootingMode: [VideoFormat]] = [:]
        if model.isPocket3 {
            formats = [.video: pocket3VideoFormats, .slowMo: pocket3SlowMoFormats,
                .superNight: pocket3LowLightFormats]
        }
        let restricted: Set<ShootingMode> = [.slowMo, .timeLapse, .superNight]
        let stops: [Double] = pro ? [1, 3, 6, 12] : pocket ? [1, 2, 4] : [1]
        let ceilings: [VideoResolution: Double] = model.isPocket3
            ? Dictionary(uniqueKeysWithValues:
                [UInt8(0x2D), 0x43, 0x5F, 0x6A].map { (VideoResolution(rawValue: $0), 3.0) }
                + [UInt8(0x10), 0x67, 0x7D, 0x6B, 0x6C].map { (VideoResolution(rawValue: $0), 2.0) })
            : [:]
        var profile = CameraCaptureProfile(labels: labels, supportsFocusMode: pocket,
            supportsTapFocus: pocket, supportsAperture: model.isAction6, hasGimbal: pocket,
            supportsZoom: pocket,
            isoAutoRangeFloor: !pro && (compact.contains("pocket4") || model.isPocket3) ? 50 : 100,
            videoFormatFallbacks: formats,
            zoom: CameraZoomProfile(stops: stops, restrictedModes: restricted,
                restrictedStops: pro ? [1, 3] : [1], resolutionCeilings: ceilings),
            looks: DJICameraLUTProfile.make(for: model),
            nativeISO: nativeISO(for: model))
        profile.controls = controls(for: model)
        return profile
    }

    /// Every Osmo body answers the Auto ISO ceiling (`0x02/0x8E` pid `0x000F`) and takes the
    /// native ISO hop on a colour change (the hop itself only moves between curves with a base
    /// ISO). A drone declares neither (unknown).
    static func nativeISO(for model: CameraModel) -> CaptureNativeISOCapabilities {
        model.isDrone ? .init() : .init(hop: true, ceiling: true)
    }

    /// Families no setting descriptor carries. Every Osmo body records video in a format and
    /// colour mode the camera lists, takes photos, serves its card and deletes from it, and has no
    /// built-in ND. Face metering and audio input follow nothing declared here (unknown, and audio
    /// follows the live level support). Multiview lists the bodies its captured preview policy
    /// qualifies; a listed body without a captured preview is experimental, so unknown.
    static func controls(for model: CameraModel) -> [ControlFamily: SupportStatus] {
        guard !model.isDrone else { return [:] }
        let multiview: SupportStatus =
            !MulticamSupport.appears(model) ? .unsupported
            : MulticamSupport.hasPreview(model) ? .supported : .unknown
        return [
            .ndFilter: .unsupported, .recordingFormat: .supported,
            .codecColor: ColorMode.catalogueModes(for: model).isEmpty ? .unknown : .supported,
            .photo: .supported, .media: .supported, .mediaDelete: .supported, .multiview: multiview,
        ]
    }

    /// Accepted Pocket 3 Video `0x02/0x18` pairs: landscape 1080/2.7K/4K and
    /// square 1080/2160/3K. Catalog 9:16 bytes were not an accepted SET.
    private static let pocket3VideoFormats: [VideoFormat] = [
        VideoResolution.p1080, .p2_7K, .p4K,
        .p1080_1x1, .p2160_1x1, .p3K_1x1,
    ].flatMap { resolution in
        VideoFrameRate.labeledVideo.map { VideoFormat(resolution: resolution, frameRate: $0) }
    }

    /// Accepted Pocket 3 SlowMo `0x02/0x18` pairs (4K 100/120, 2.7K 120, 1080 120/240).
    private static let pocket3SlowMoFormats: [VideoFormat] = [
        VideoFormat(resolution: .p4K, frameRate: .fps100),
        VideoFormat(resolution: .p4K, frameRate: .fps120),
        VideoFormat(resolution: .p2_7K, frameRate: .fps120),
        VideoFormat(resolution: .p1080, frameRate: .fps120),
        VideoFormat(resolution: .p1080, frameRate: .fps240),
    ]

    /// Accepted Pocket 3 Low-Light pairs: 1080 / 4K at 24 / 25 / 30. No 2.7K or square.
    private static let pocket3LowLightFormats: [VideoFormat] = [
        VideoResolution.p1080, .p4K,
    ].flatMap { resolution in
        [VideoFrameRate.fps24, .fps25, .fps30].map {
            VideoFormat(resolution: resolution, frameRate: $0)
        }
    }

}

extension ColorMode {
    /// Action 6 `camcap_color_mode` is `3F` Normal 10-bit / `3D` D-Log M (survey
    /// 2026-09-21): the Nano wire bytes, without Nano's 8-bit `00`.
    public static let action6: [ColorMode] = [.normal10, .dLogM]

    /// Family fallback. Pocket 4 Pro is the only body with D-Log2 — use
    /// `available(for: CameraModel)` when the name is known.
    public static func available(for family: CameraBodyFamily) -> [ColorMode] {
        switch family {
        case .nano: [.normal, .normal10, .dLogM]
        case .pocket, .other: [.normal, .hdr, .dLog]
        }
    }

    /// DJI comparison: 4 Pro D-Log2 / D-Log; Pocket 4 D-Log; Pocket 3 HLG / D-Log M.
    /// Nano is the captured `camcap_color_mode` wheel. D-Log2 is 4 Pro only.
    static func catalogueModes(for model: CameraModel) -> [ColorMode] {
        if model.family == .nano { return available(for: .nano) }
        if model.isAction6 { return action6 }
        let n = model.name.lowercased().replacingOccurrences(of: " ", with: "")
        if n.contains("pocket4p") || n.contains("4pro") {
            return [.normal, .hdr, .dLog, .dLog2]
        }
        if n.contains("pocket4") { return [.normal, .hdr, .dLog] }
        if model.isPocket3 {
            return [.normal, .hdr, .dLogM]
        }
        return available(for: model.family)
    }

}

extension CamCapColorMode {
    public static func wheel(available: [ColorMode], family: CameraBodyFamily) -> [ColorMode] {
        wheel(available: available, order: ColorMode.available(for: family))
    }
}

extension ColorMode {
    /// Compatibility labels for the integration's family catalogue.
    public func label(for family: CameraBodyFamily) -> String {
        let labels: CameraLabelProfile
        switch family {
        case .pocket: labels = CameraLabelProfile(colorModeLabels: [.dLogM: "D-Log M"])
        case .nano: labels = CameraLabelProfile(colorModeLabels: [.normal: "Normal 8-bit"])
        case .other: labels = .standard
        }
        return label(in: labels)
    }
}
