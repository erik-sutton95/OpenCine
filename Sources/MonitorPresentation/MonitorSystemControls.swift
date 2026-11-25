import Foundation

/// Optional system controls, after the operator's display customization is applied.
/// Recording keeps Stop and Settings reachable even in a clean display mode.
public struct MonitorSystemControlsVisibility: Equatable, Sendable {
    public var lock: Bool
    public var settings: Bool
    public var media: Bool
    public var record: Bool
    public var display: Bool

    public init(lock: Bool = true, settings: Bool = true, media: Bool = true,
        record: Bool = true, display: Bool = true) {
        self.lock = lock
        self.settings = settings
        self.media = media
        self.record = record
        self.display = display
    }

    public func resolved(locked: Bool, recording: Bool?, borrowed: Bool) -> Self {
        var result = self
        result.lock = lock || locked
        result.settings = settings || recording == true
        result.record = record || recording == true
        result.media = media && !borrowed
        return result
    }

    /// As `resolved(locked:recording:borrowed:)`, for a chrome style. A desktop window has no
    /// interface lock, and its toolbar holds Settings and Media, so the picture draws none of them.
    public func resolved(locked: Bool, recording: Bool?, borrowed: Bool, chrome: MonitorChromeStyle) -> Self {
        guard chrome == .desktop else { return resolved(locked: locked, recording: recording, borrowed: borrowed) }
        var result = resolved(locked: false, recording: recording, borrowed: borrowed)
        result.lock = false
        result.settings = false
        result.media = false
        return result
    }
}
