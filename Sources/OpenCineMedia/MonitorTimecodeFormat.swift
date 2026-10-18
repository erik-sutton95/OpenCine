import Foundation

/// Display precision follows supplied telemetry. Missing frames stay seconds-only.
public enum MonitorTimecodeFormat {
    /// Formats reported components without deriving frames, rates, or drop-frame mode.
    /// Invalid components are unavailable rather than normalized into a plausible clock.
    public static func label(
        hours: Int, minutes: Int, seconds: Int, frames: Int? = nil, dropFrame: Bool? = nil
    ) -> String? {
        guard (0...23).contains(hours), (0...59).contains(minutes),
            (0...59).contains(seconds), frames.map({ $0 >= 0 }) ?? true
        else { return nil }
        let clock = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        guard let frames else { return clock }
        let separator = dropFrame == true ? ";" : ":"
        let digits = String(frames)
        return clock + separator + (digits.count < 2 ? "0" + digits : digits)
    }

    /// The empty clock at the declared precision: a frame-counting source keeps its frame field.
    public static func placeholder(frames: Bool) -> String { frames ? "--:--:--:--" : "--:--:--" }

    /// Splits the final seconds or frames field for the shared clock's accent color.
    public static func accentComponents(in label: String) -> (base: String, accent: String) {
        guard let separator = label.lastIndex(where: { $0 == ":" || $0 == ";" }) else {
            return (label, "")
        }
        return (String(label[...separator]), String(label[label.index(after: separator)...]))
    }
}
