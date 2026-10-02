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
}
