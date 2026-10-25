import Foundation

/// The picture the source delivers: its aspect, whether the first frame is still awaited,
/// whether the camera shows it vertically or upside down, and whether the link is recovering. A
/// `notice` replaces the waiting plate's words when the source has no picture to wait for (no
/// camera, a reconnect, a network hop). Twin of the Compose `MonitorOperatorLivePicture`.
public struct MonitorOperatorLivePicture: Equatable {
    public let aspect: Double
    public let waiting: Bool
    public let vertical: Bool
    public let flipped: Bool
    public let recovering: Bool
    /// An automatic reconnect is running: the "Reconnecting" pill. `nil` at init follows
    /// `recovering`. A source whose recovery can wait for the operator (taken over, paused, out
    /// of attempts) passes it apart, so the pill never contradicts the recovery card.
    public let reconnecting: Bool
    public let notice: MonitorOperatorPictureNotice?
    public init(
        aspect: Double, waiting: Bool, vertical: Bool, flipped: Bool, recovering: Bool,
        reconnecting: Bool? = nil, notice: MonitorOperatorPictureNotice? = nil
    ) {
        self.aspect = aspect
        self.waiting = waiting
        self.vertical = vertical
        self.flipped = flipped
        self.recovering = recovering
        self.reconnecting = reconnecting ?? recovering
        self.notice = notice
    }
    /// The plate covers the picture well: the source's notice, else the waiting plate.
    public var plate: MonitorOperatorPicturePlate? {
        if let notice { return .notice(notice) }
        return waiting ? .waiting : nil
    }
}

/// The picture well's own words: a title, an optional detail, and whether work is under way (a
/// spinner). Twin of the Compose `MonitorOperatorPictureNotice`.
public struct MonitorOperatorPictureNotice: Equatable, Sendable {
    public let title: String
    public let detail: String?
    public let progress: Bool
    public init(title: String, detail: String? = nil, progress: Bool = false) {
        self.title = title
        self.detail = detail
        self.progress = progress
    }
}

/// What covers the picture well: the waiting plate, or the plate's look with the source's notice.
public enum MonitorOperatorPicturePlate: Equatable, Sendable {
    case waiting
    case notice(MonitorOperatorPictureNotice)
}
