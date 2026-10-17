import OpenCineMedia

/// Presentation of the exposure meter: the camera's metered EV, or for a camera that meters
/// none a picture estimate its source supplies, marked as estimated. Never the operator's
/// configured exposure compensation.
public struct ExposureMeterReading: Equatable, Sendable {
    /// Metered exposure in stops; nil while unknown. A camera meters in thirds or sixths.
    public let stops: Double?
    /// The value is estimated from the picture, not reported by the camera.
    private let imageEstimated: Bool

    public init(stops: Double?, imageEstimated: Bool = false) {
        self.stops = stops.flatMap { $0.isFinite ? $0 : nil }
        self.imageEstimated = imageEstimated
    }

    public init(cameraValue: EvComp?, imageEstimated: Bool = false) {
        self.init(stops: cameraValue.map { Double($0.thirds) / 3 }, imageEstimated: imageEstimated)
    }

    /// 0 at −3 EV, 1 at +3 EV. Scaled through thirds so a reported third lands exactly.
    public var needleFraction: Double? { stops.map { (min(3, max(-3, $0)) * 3 + 9) / 18 } }
    public var label: String { stops.map(ExposureCompensation.label(stops:)) ?? "\u{2014}" }

    public var accessibilityValue: String {
        if stops == nil { return "Unavailable, waiting for camera EV" }
        return imageEstimated ? "Estimated from picture \(label) EV" : "Camera exposure \(label) EV"
    }
}
