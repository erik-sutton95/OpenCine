import Foundation

/// Detector paint values, independent of display-theme swatches.
public enum MonitorPeakingColor: String, CaseIterable, Codable, Sendable, Identifiable {
    case white = "White"
    case blue = "Blue"
    case red = "Red"
    case green = "Green"
    public var id: String { rawValue }
    public var rgb: (Double, Double, Double) {
        switch self {
        case .white: (246.0 / 255, 241.0 / 255, 226.0 / 255)
        case .blue: (64.0 / 255, 142.0 / 255, 1)
        case .red: (1, 72.0 / 255, 64.0 / 255)
        case .green: (74.0 / 255, 220.0 / 255, 132.0 / 255)
        }
    }
}

public enum MonitorPeakingSense: String, CaseIterable, Codable, Sendable, Identifiable {
    case low = "Low"
    case medium = "Med"
    case high = "High"
    public var id: String { rawValue }
    public var ratioThreshold: Double {
        switch self { case .low: 2.30; case .medium: 2.10; case .high: 1.90 }
    }
    public var noiseGate: Double {
        switch self { case .low: 0.00522; case .medium: 0.00174; case .high: 0.00058 }
    }
}

public struct MonitorPeakingOptions: Equatable, Codable, Sendable {
    public var color: MonitorPeakingColor
    public var sensitivity: MonitorPeakingSense
    public init(color: MonitorPeakingColor, sensitivity: MonitorPeakingSense) {
        self.color = color
        self.sensitivity = sensitivity
    }
    public static let `default` = Self(color: .red, sensitivity: .medium)
    public var overlay: MonitorPeakingOverlaySpec {
        MonitorPeakingOverlaySpec(color: color, sensitivity: sensitivity)
    }
}

public struct MonitorPeakingOverlaySpec: Equatable, Sendable {
    public var color: MonitorPeakingColor
    public var sensitivity: MonitorPeakingSense
    public init(color: MonitorPeakingColor, sensitivity: MonitorPeakingSense) {
        self.color = color
        self.sensitivity = sensitivity
    }
    public var rgb: (Double, Double, Double) { color.rgb }
    public var ratioThreshold: Double { sensitivity.ratioThreshold }
    public var noiseGate: Double { sensitivity.noiseGate }
}

public enum MonitorZebraPaint: String, CaseIterable, Codable, Sendable, Identifiable {
    case white = "White"
    case amber = "Amber"
    case red = "Red"
    case cyan = "Cyan"
    case green = "Green"
    public var id: String { rawValue }
    public var rgb: (Double, Double, Double) {
        switch self {
        case .white: (1, 1, 1)
        case .amber: (1, 0.72, 0.2)
        case .red: (1, 0.15, 0.15)
        case .cyan: (0, 0.85, 0.9)
        case .green: (0.2, 0.9, 0.35)
        }
    }
}

/// Persisted compensation identities are shared by histogram and traffic-light meters.
public enum MonitorCrushClipCompensation: Int, CaseIterable, Codable, Sendable, Identifiable {
    case zero = 0
    case quarter = 2
    case half = 5
    case threeQuarter = 7
    case one = 10
    public var id: Int { rawValue }
    public var label: String {
        switch self {
        case .zero: "0"; case .quarter: "0.25"; case .half: "0.5"
        case .threeQuarter: "0.75"; case .one: "1.0"
        }
    }
    public var compactLabel: String {
        switch self {
        case .zero: "0"; case .quarter: "¼"; case .half: "½"
        case .threeQuarter: "¾"; case .one: "1"
        }
    }
    public var stops: Double {
        switch self {
        case .zero: 0; case .quarter: 0.25; case .half: 0.5
        case .threeQuarter: 0.75; case .one: 1
        }
    }
    public var pixelFractionThreshold: Double { stops / 10 }
    public static func fromRaw(_ value: Int) -> Self {
        Self(rawValue: value) ?? (value > 10 ? .one : .zero)
    }
    public init(from decoder: any Decoder) throws {
        self = Self.fromRaw(try decoder.singleValueContainer().decode(Int.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Local presentation correction; sampling and delivered source pixels are unchanged.
public enum MonitorDesqueezePreset: String, CaseIterable, Codable, Sendable {
    case x11 = "1.1×"
    case x12 = "1.2×"
    case x133 = "1.33×"
    case x15 = "1.5×"
    case x16 = "1.6×"
    case x18 = "1.8×"
    case x2 = "2.0×"
    public var factor: Double {
        switch self {
        case .x11: 1.1; case .x12: 1.2; case .x133: 1.33
        case .x15: 1.5; case .x16: 1.6; case .x18: 1.8; case .x2: 2
        }
    }
    public static func matching(_ factor: Double) -> Self? {
        allCases.first { abs($0.factor - factor) < 0.005 }
    }
}

public enum MonitorDesqueezeDirection: String, CaseIterable, Sendable {
    case horizontal = "Horizontal"
    case vertical = "Vertical"
}

public enum MonitorAnamorphicDesqueeze {
    public static let factorRange = 1.0...2.0
    public static let factorStep = 0.01
    public static func snap(_ value: Double) -> Double {
        let finite = value.isFinite ? value : 1.33
        return (min(2, max(1, finite)) * 100 + 0.000_000_1).rounded() / 100
    }
    public static func label(_ value: Double) -> String {
        String(format: "%.2f×", locale: Locale(identifier: "en_US_POSIX"), snap(value))
    }
    public static func aspect(
        sourceAspect: Double?, enabled: Bool, factor: Double,
        direction: MonitorDesqueezeDirection
    ) -> Double? {
        guard let sourceAspect, sourceAspect.isFinite, sourceAspect > 0 else { return nil }
        guard enabled else { return sourceAspect }
        let correction = snap(factor)
        return direction == .horizontal ? sourceAspect * correction : sourceAspect / correction
    }
}
