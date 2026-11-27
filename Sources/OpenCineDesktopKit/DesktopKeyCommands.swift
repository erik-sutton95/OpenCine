import Foundation

/// A module window's keyboard action.
public enum DesktopShortcut: Equatable, Hashable, Sendable {
    /// Start or stop recording.
    case record
    /// The camera's settings.
    case settings
    /// Media.
    case media
    /// The tab at this index, as a click on it.
    case tab(Int)
    case nextTab
    case previousTab
    /// The display overlays (DISP).
    case overlays
}

/// The modifier keys of a key press.
public struct DesktopModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1 << 0)
    public static let shift = Self(rawValue: 1 << 1)
    public static let control = Self(rawValue: 1 << 2)
    public static let option = Self(rawValue: 1 << 3)
}

/// The module window's key table: ⌘R record, ⌘, settings, ⌘⇧M media, ⌘1 to ⌘9 a tab, ⌃⇥ and
/// ⌃⇧⇥ the next and previous tab, D the display overlays.
public enum DesktopKeyCommands {
    /// One key the window registers.
    public struct Key: Equatable, Sendable {
        public var input: String
        public var modifiers: DesktopModifiers
    }

    /// Every key the window registers, each answered by `action`.
    public static let registered: [Key] =
        [
            Key(input: "r", modifiers: .command),
            Key(input: ",", modifiers: .command),
            Key(input: "m", modifiers: [.command, .shift]),
        ]
        + (1...9).map { Key(input: "\($0)", modifiers: .command) }
        + [
            Key(input: "\t", modifiers: .control),
            Key(input: "\t", modifiers: [.control, .shift]),
            Key(input: "d", modifiers: []),
        ]

    /// The action for a key press, or nil when it is not one: a plain key while text has focus
    /// types its letter, and a tab shortcut beyond the tabs does nothing.
    public static func action(
        input: String, modifiers: DesktopModifiers, textHasFocus: Bool, tabCount: Int
    ) -> DesktopShortcut? {
        let key = input.lowercased()
        switch modifiers {
        case .command:
            switch key {
            case "r": return .record
            case ",": return .settings
            default:
                guard let number = Int(key), (1...9).contains(number), number <= tabCount else { return nil }
                return .tab(number - 1)
            }
        case [.command, .shift]:
            return key == "m" ? .media : nil
        case .control:
            return key == "\t" && tabCount > 1 ? .nextTab : nil
        case [.control, .shift]:
            return key == "\t" && tabCount > 1 ? .previousTab : nil
        case []:
            return key == "d" && !textHasFocus ? .overlays : nil
        default:
            return nil
        }
    }

    /// The tab a tab shortcut selects, wrapping around; nil for any other action or a missing tab.
    public static func tabIndex(for shortcut: DesktopShortcut, selected: Int?, tabCount: Int) -> Int? {
        guard tabCount > 0 else { return nil }
        switch shortcut {
        case .tab(let index): return (0..<tabCount).contains(index) ? index : nil
        case .nextTab: return selected.map { ($0 + 1) % tabCount } ?? 0
        case .previousTab: return selected.map { ($0 + tabCount - 1) % tabCount } ?? tabCount - 1
        case .record, .settings, .media, .overlays: return nil
        }
    }
}

/// The take as the module window's toolbar shows it: standing by or recording, with the timecode.
public enum DesktopTake: Equatable, Sendable {
    case standby(timecode: String?)
    case recording(timecode: String?)
    /// The monitor does not know whether the body records (no control link yet, or it dropped).
    case unknown(timecode: String?)

    /// The take from the monitor's recording state, nil while unknown.
    public init(recording: Bool?, timecode: String?) {
        switch recording {
        case true?: self = .recording(timecode: timecode)
        case false?: self = .standby(timecode: timecode)
        case nil: self = .unknown(timecode: timecode)
        }
    }

    public enum Role: Equatable, Sendable {
        /// Standing by: the muted text colour.
        case muted
        /// The recording colour.
        case recording
    }

    /// What the toolbar prints and how it colours it.
    public struct Title: Equatable, Sendable {
        /// Nil while the recording state is unknown: no state word, never a false STBY.
        public var state: String?
        /// Nil when the camera reports none: the state shows alone, never a dash.
        public var timecode: String?
        public var role: Role
    }

    public var isRecording: Bool {
        if case .recording = self { true } else { false }
    }

    public var title: Title {
        switch self {
        case .standby(let timecode): Title(state: "STBY", timecode: Self.shown(timecode), role: .muted)
        case .recording(let timecode): Title(state: "REC", timecode: Self.shown(timecode), role: .recording)
        case .unknown(let timecode): Title(state: nil, timecode: Self.shown(timecode), role: .muted)
        }
    }

    private static func shown(_ timecode: String?) -> String? {
        guard let value = timecode?.trimmingCharacters(in: .whitespaces), !value.isEmpty,
            value.contains(where: \.isNumber)
        else { return nil }
        return value
    }
}

/// The actions a window currently runs, and which monitor registered them. A monitor that leaves
/// the screen clears only its own registration, so one that left after a newer one registered
/// leaves the newer one's actions in place.
public struct DesktopRegistry<Value> {
    /// Who registered: one per monitor on screen.
    public struct Owner: Hashable, Sendable {
        let id: UUID
        public init(_ id: UUID = UUID()) { self.id = id }
    }

    public private(set) var current: Value?
    private var owner: Owner?

    public init() {}

    public mutating func register(_ value: Value, owner: Owner) {
        current = value
        self.owner = owner
    }

    public mutating func unregister(owner: Owner) {
        guard self.owner == owner else { return }
        current = nil
        self.owner = nil
    }
}
