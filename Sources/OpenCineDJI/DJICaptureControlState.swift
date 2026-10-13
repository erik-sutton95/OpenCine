import Foundation
import OpenCineCore

/// Actual decoded camera reports, before any pending UI value is applied.
/// A connection owner keeps this separate from its presentation status.
public struct DJICaptureControlState: Sendable {
    public var reported: CameraStatus
    public var model: CameraModel?

    public init(reported: CameraStatus, model: CameraModel?) {
        self.reported = reported
        self.model = model
    }

    var descriptors: [SettingDescriptor] {
        guard let model else { return [] }
        let shutter = reported.availableShutterDenoms.filter { $0 > 0 }.map {
            SettingValue.shutter(.duration(Rational(1, $0)))
        }
        var result = [
            SettingDescriptor(
                .shutter, access: shutter.isEmpty ? .readOnly : .readWrite,
                domain: SettingDomain(choices: shutter),
                availability: reported.expoMode == .manual ? .available : .unavailable(.mode)),
            SettingDescriptor(
                .exposureCompensation,
                domain: SettingDomain(choices: EvComp.allCases.map {
                    .exposureCompensation(Rational($0.thirds, 3))
                })),
        ]
        if model.supportsFocusMode {
            result.append(SettingDescriptor(
                .focusMode, domain: SettingDomain(choices: [
                    .focusMode(.single), .focusMode(.continuous),
                ])))
        }
        if model.supportsZoom {
            let stops = model.activeZoomStops(
                resolution: reported.videoResolution, shootingMode: reported.shootingMode)
            if let maximum = stops.last, maximum.isFinite, maximum >= 1 {
                result.append(SettingDescriptor(
                    .zoom, domain: SettingDomain(range: 1...maximum)))
            }
        }
        if model.supportsAperture {
            // Strategy Auto/Starburst is not a common f-number command.
            // The measured mechanical iris is a common read-only observation.
            result.append(SettingDescriptor(.aperture, access: .readOnly))
        }
        // The recording rate is a common read-only observation; the format picker stays native.
        result.append(SettingDescriptor(.frameRate, access: .readOnly))
        return result
    }

    var settings: [SettingKey: ObservedValue<SettingValue>] {
        var result: [SettingKey: ObservedValue<SettingValue>] = [:]
        func report(_ value: SettingValue) {
            result[value.key] = ObservedValue(value, origin: .cameraReported, at: nil)
        }
        if reported.shutterDenom > 0 {
            report(.shutter(.duration(Rational(1, reported.shutterDenom))))
        }
        if let value = reported.evComp {
            report(.exposureCompensation(Rational(value.thirds, 3)))
        }
        if let value = reported.focusMode {
            report(.focusMode(value == .single ? .single : .continuous))
        }
        if let value = reported.zoomFactor, value.isFinite, value >= 1 {
            report(.zoom(value))
        }
        if let value = reported.irisHundredths, (100...2_200).contains(value) {
            report(.aperture(Double(value) / 100))
        }
        // `cam_video_param_v2` carries an index into whole rates (`VideoFrameRate`).
        if reported.fps > 0 {
            report(.frameRate(Rational(reported.fps)))
        }
        return result
    }
}

extension DJIControlPort {
    /// Older callers keep their existing capabilities until they supply actual reports.
    public var captureControlState: DJICaptureControlState? { nil }
    public func writeShutter(
        _ denominator: Int, onStage: @escaping @MainActor (ControlWireEvent) -> Void
    ) { onStage(.notSent) }
    public func writeExposureCompensation(
        _ value: EvComp, onStage: @escaping @MainActor (ControlWireEvent) -> Void
    ) { onStage(.notSent) }
    public func writeFocusMode(
        _ value: OpenCineCameraVocabulary.FocusMode, onStage: @escaping @MainActor (ControlWireEvent) -> Void
    ) { onStage(.notSent) }
    public func writeZoom(
        _ ratio: Double, onStage: @escaping @MainActor (ControlWireEvent) -> Void
    ) { onStage(.notSent) }
}
