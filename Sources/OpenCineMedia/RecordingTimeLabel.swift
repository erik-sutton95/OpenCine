import OpenCineCore

/// Recording minutes keep the observation's provenance on local and relayed surfaces.
public enum RecordingTimeLabel {
    public static func label(_ minutes: Int64?, origin: ObservationOrigin) -> String? {
        guard let minutes, minutes >= 0 else { return nil }
        return (origin == .estimated ? "~" : "") + "\(minutes) Min"
    }
}
