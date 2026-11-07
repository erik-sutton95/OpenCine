import Foundation

/// Timed script movement in logical display points, independent of rendering and camera state.
public struct TeleprompterPlayback: Equatable, Sendable {
    /// Current vertical position in the script.
    public private(set) var position: Double = 0
    /// Whether elapsed time should advance the script.
    public private(set) var isPlaying: Bool = false

    /// Creates a paused script at its beginning.
    public init() {}

    /// Resumes from the current position. Reaching the end requires a reset or manual scroll.
    public mutating func play() { isPlaying = true }

    /// Pauses without losing the reading position.
    public mutating func pause() { isPlaying = false }

    /// Pauses and returns to the beginning.
    public mutating func reset() {
        position = 0
        pause()
    }

    /// Takes the position from a native manual scroll and pauses automatic movement.
    public mutating func seek(to position: Double) {
        self.position = max(0, position)
        pause()
    }

    /// Advances by actual elapsed time and stops once the last readable position is reached.
    public mutating func advance(elapsed: TimeInterval, speed: Double, end: Double) {
        guard isPlaying else { return }
        position = min(max(0, end), position + max(0, elapsed) * max(0, speed))
        if position >= max(0, end) { pause() }
    }
}
