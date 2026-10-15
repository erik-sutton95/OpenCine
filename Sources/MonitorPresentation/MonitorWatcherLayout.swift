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

/// The one watcher passcode rule, shared by the broadcaster's setting and the watcher's join
/// entry on every app and both platforms (Android twin: `MonitorWatcherPasscodeRule`).
///
/// A passcode is any text of at least ``minimumLength`` characters (Unicode scalars, so both
/// platforms count alike) once surrounding whitespace is trimmed; an empty one means an open
/// broadcast. The relay compares codes after the same trim
/// (`RelayJoinPolicy`), so what one side accepts the other side matches.
///
/// The minimum judges only a code being chosen now. A code saved before this rule (four digits on
/// one app, free text of any length on others) stays in force: hosts keep requiring it, watchers
/// keep sending it, and a watcher may answer any non-empty code because only the host knows
/// which code it requires.
public enum MonitorWatcherPasscodeRule {
    public static let minimumLength = 4

    /// Shown under a broadcaster's entry that is not yet long enough to take effect.
    public static let tooShortHint = "At least 4 characters, or empty for an open feed."

    /// What a broadcaster's entry means.
    public enum Entry: Equatable, Sendable {
        /// Empty: the broadcast is open.
        case open
        /// A passcode to require, trimmed.
        case code(String)
        /// Too short to take effect; the code already in force stays.
        case tooShort

        /// The value to store and require, nil while the entry is too short.
        public var passcode: String? {
            switch self {
            case .open: ""
            case .code(let code): code
            case .tooShort: nil
            }
        }
    }

    /// Surrounding spaces, tabs and line breaks never count as part of a passcode.
    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Judges a passcode a broadcaster is choosing now.
    public static func entry(_ text: String) -> Entry {
        let code = normalized(text)
        if code.isEmpty { return .open }
        return code.unicodeScalars.count >= minimumLength ? .code(code) : .tooShort
    }

    /// A watcher's answer to a host that asked for a passcode: the trimmed code, nil when empty.
    public static func answer(_ text: String) -> String? {
        let code = normalized(text)
        return code.isEmpty ? nil : code
    }
}
