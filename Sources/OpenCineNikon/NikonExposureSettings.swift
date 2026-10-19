import Foundation
import OpenCineCore

/// Movie exposure values behind the common setting seam. Camera mode and advertised choices
/// decide the domain; setting a value never changes duration/angle mode or a stills property.
public enum NikonExposureSettings {
    /// Parses the camera's duration or angle label. Open-shutter sentinels stay integration-owned.
    public static func shutter(_ label: String) -> SettingValue? {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.hasSuffix("°"), let degrees = Double(label.dropLast()),
            degrees.isFinite, degrees > 0, degrees <= 360
        {
            return .shutter(.angle(degrees))
        }
        if label.hasSuffix("s"), let seconds = Int(label.dropLast()), seconds > 0,
            seconds <= Int(UInt16.max)
        {
            return .shutter(.duration(Rational(seconds)))
        }
        let parts = label.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let numerator = Int(parts[0]), let denominator = Int(parts[1]),
            numerator > 0, numerator <= Int(UInt16.max),
            denominator > 0, denominator <= Int(UInt16.max)
        else { return nil }
        return .shutter(.duration(Rational(numerator, denominator)))
    }

    /// Parses the body's f-number without inventing an aperture for an unknown lens.
    public static func aperture(_ label: String) -> SettingValue? {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard label.hasPrefix("f/"), let value = Double(label.dropFirst(2)),
            value.isFinite, value > 0, value * 100 <= Double(UInt16.max - 1)
        else { return nil }
        return .aperture(value)
    }

    /// Canonical label accepted by the existing Nikon property encoder.
    public static func label(_ value: SettingValue) -> String? {
        switch value {
        case .shutter(.angle(let angle)):
            guard angle.isFinite, angle > 0, angle <= 360 else { return nil }
            return String(format: "%g°", angle)
        case .shutter(.duration(let duration)):
            guard duration.numerator > 0, duration.numerator <= Int(UInt16.max),
                duration.denominator > 0, duration.denominator <= Int(UInt16.max)
            else { return nil }
            return "\(duration.numerator)/\(duration.denominator)"
        case .aperture(let aperture):
            guard aperture.isFinite, aperture > 0, aperture * 100 <= Double(UInt16.max - 1)
            else { return nil }
            return String(format: "f/%g", aperture)
        default: return nil
        }
    }

    /// Readback values follow the active circuit. Stills do not become movie facts. A body that
    /// never reports `MovieShutterMode` (only the ZR does) shows the circuit it reports, angle
    /// first.
    public static func reported(_ properties: PTPCameraPropertySnapshot) -> [SettingKey:
        SettingValue?]
    {
        guard properties.captureSelector == .video else { return [.shutter: nil, .aperture: nil] }
        let shutter: SettingValue? =
            switch properties.shutterMode {
            case .angle: properties.shutterAngle.flatMap(Self.shutter)
            case .speed: properties.shutterSpeed.flatMap(Self.shutter)
            case nil: (properties.shutterAngle ?? properties.shutterSpeed).flatMap(Self.shutter)
            }
        return [.shutter: shutter, .aperture: properties.fNumber.flatMap(Self.aperture)]
    }

    /// The active movie write domain. A reported value does not imply permission to write it.
    /// Locks and unknown prerequisites
    /// constrain admission; the existing transaction encoder and body remain write authorities.
    /// While the shutter mode is unknown the encoder writes by label shape, so each circuit the
    /// body reports a value for is the domain: the advertised labels, else the picker ladders.
    /// A body that reports no shutter value publishes no shutter descriptor.
    public static func descriptors(
        _ properties: PTPCameraPropertySnapshot, shutterLabels: [String], apertureLabels: [String]
    ) -> [SettingDescriptor] {
        guard properties.captureSelector == .video else { return [] }
        let reported = Self.reported(properties)
        // Flatten unknown dictionary values before admission checks.
        let reportedShutter: SettingValue? = reported[.shutter].flatMap { $0 }
        let reportedAperture: SettingValue? = reported[.aperture].flatMap { $0 }
        let labels =
            properties.shutterMode == nil && shutterLabels.isEmpty
            ? ShutterPickerPolicy.angleOptions + ShutterPickerPolicy.speedOptions : shutterLabels
        let shutter = unique(
            labels.compactMap(Self.shutter).filter {
                switch ($0, properties.shutterMode) {
                case (.shutter(.angle), .angle), (.shutter(.duration), .speed): true
                // Unknown mode: only a circuit the body reports a value for is writable.
                case (.shutter(.angle), nil): properties.shutterAngle != nil
                case (.shutter(.duration), nil): properties.shutterSpeed != nil
                default: false
                }
            })
        let aperture = unique(apertureLabels.compactMap(Self.aperture))
        var result: [SettingDescriptor] = []
        if !shutter.isEmpty || reportedShutter != nil {
            result.append(
                SettingDescriptor(
                    .shutter, domain: SettingDomain(choices: shutter),
                    availability: shutter.isEmpty
                        ? .unavailable(.notReady)
                        : properties.shutterLocked == true ? .unavailable(.busy) : .available))
        }
        if !aperture.isEmpty || reportedAperture != nil {
            result.append(
                SettingDescriptor(
                    .aperture, domain: SettingDomain(choices: aperture),
                    availability: aperture.isEmpty ? .unavailable(.notReady) : .available))
        }
        return result
    }

    private static func unique(_ values: [SettingValue]) -> [SettingValue] {
        var seen: Set<SettingValue> = []
        return values.filter { seen.insert($0).inserted }
    }
}
