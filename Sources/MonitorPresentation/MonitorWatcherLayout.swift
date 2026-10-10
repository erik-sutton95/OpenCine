import Foundation

/// The common watcher measures the picture; native leaves only consume this source-bound value.
public struct MonitorWatcherPictureGeometry: Equatable, Sendable {
    public let source: MonitorWatcherTapSource
    public let viewport: MonitorRect
    public let feed: MonitorRect
    public let bottomClearance: Double
    public let mirrored: Bool
    public init(source: MonitorWatcherTapSource, viewport: MonitorRect, feed: MonitorRect,
        bottomClearance: Double, mirrored: Bool) {
        self.source = source; self.viewport = viewport; self.feed = feed
        self.bottomClearance = bottomClearance; self.mirrored = mirrored
    }
    public func belongs(to current: MonitorWatcherTapSource) -> Bool {
        source.source == current.source && source.revision == current.revision
    }
}

/// Existing relay key lane above the monitor's system and assist bars, in points or dp.
public enum MonitorWatcherControlPlacement {
    public static func bottomInset(portrait: Bool) -> Double { portrait ? 192 : 84 }
}

/// Common notice wording. The adapter maps its transport phase, without owning presentation policy.
public enum MonitorWatcherNotices {
    public static var joining: MonitorWatcherNotice { .init("Joining shared feed…") }
    public static var waitingForPicture: MonitorWatcherNotice { .init("Waiting for picture from the host…") }
    public static func reconnecting(attempt: Int, maximum: Int) -> MonitorWatcherNotice {
        .init("Reconnecting… \(attempt) of \(maximum)")
    }
    public static func failed(_ message: String) -> MonitorWatcherNotice { .init(message, canChooseFeed: true) }
}

public enum MonitorWatcherConnectionPhase: Equatable, Sendable { case joining, watching, denied, failed }
/// Optional join/control overlay facts, used when the shared live surface already owns picture/tools.
public struct MonitorWatcherConnectionOverlayValue: Equatable, Sendable {
    public let phase: MonitorWatcherConnectionPhase
    public let canControl: Bool
    public let canRequestControl: Bool
    public let needsPasscode: Bool
    public let passcodeWasWrong: Bool
    public let failureReason: String?
    public let controlBottomInset: Double
    public init(phase: MonitorWatcherConnectionPhase, canControl: Bool, canRequestControl: Bool,
        needsPasscode: Bool, passcodeWasWrong: Bool, failureReason: String?, controlBottomInset: Double) {
        self.phase = phase; self.canControl = canControl; self.canRequestControl = canRequestControl
        self.needsPasscode = needsPasscode; self.passcodeWasWrong = passcodeWasWrong
        self.failureReason = failureReason; self.controlBottomInset = controlBottomInset
    }
}

/// Saved passcode UI retains the deployed four-decimal-digit entry rule; wire credentials stay outside UI.
public struct MonitorWatcherPasscodeDraft: Equatable, Sendable {
    public private(set) var digits = ""
    public init() {}
    public mutating func update(_ text: String) {
        digits = String(String.UnicodeScalarView(text.unicodeScalars.filter {
            $0.value <= 0xFFFF && $0.properties.generalCategory == .decimalNumber
        }.prefix(4)))
    }
    public var complete: String? { digits.count == 4 ? digits : nil }
}
