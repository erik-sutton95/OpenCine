/// Presentation of the camera's exposure meter. Never derived from preview pixels
/// or from the operator's configured exposure compensation.
public struct ExposureMeterReading: Equatable, Sendable {
    private let cameraValue: EvComp?
    /// The value is estimated from the picture, not reported by the camera.
    private let imageEstimated: Bool

    public init(cameraValue: EvComp?, imageEstimated: Bool = false) {
        self.cameraValue = cameraValue
        self.imageEstimated = imageEstimated
    }

    public var stops: Double? { cameraValue.map { Double($0.thirds) / 3 } }
    public var needleFraction: Double? { cameraValue.map { Double($0.thirds + 9) / 18 } }
    public var label: String { cameraValue?.label ?? "\u{2014}" }

    public var accessibilityValue: String {
        if cameraValue == nil { return "Unavailable, waiting for camera EV" }
        return imageEstimated ? "Estimated from picture \(label) EV" : "Camera exposure \(label) EV"
    }
}
