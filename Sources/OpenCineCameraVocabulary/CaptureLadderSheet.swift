import OpenCineCore

// The ladder popup as values: a camera integration builds it from what the body advertises,
// and the shared `LadderSheet` (OpenCineCameraControls) draws it inside the common drawer.

/// A tab whose drum is a typed common setting: the values the camera offers on this tab, in the
/// common vocabulary, so the drum shows the session's field limited to them.
public struct CaptureLadderSetting: Equatable, Sendable {
    public let key: SettingKey
    public let offered: [SettingValue]

    public init(key: SettingKey, offered: [SettingValue]) {
        self.key = key
        self.offered = offered
    }
}

/// One write the sheet asks the host to make: the host's own key and a camera label.
public struct LadderWrite<Key: Equatable & Sendable>: Equatable, Sendable {
    public let key: Key
    public let value: String

    public init(key: Key, value: String) {
        self.key = key
        self.value = value
    }
}

/// A button beside the drum's selected value (Kelvin -10/+10, a codec's two bit depths).
/// `value` nil disables the button. `lands` true means the written value becomes the drum's value.
public struct LadderStep: Equatable, Sendable {
    public let label: String
    public let value: String?
    public let description: String
    public let selected: Bool
    public let lands: Bool

    public init(
        label: String, value: String?, description: String, selected: Bool = false,
        lands: Bool = false
    ) {
        self.label = label
        self.value = value
        self.description = description
        self.selected = selected
        self.lands = lands
    }
}

/// One tab: a typed common setting (drawn by `MonitorCaptureDrum` when the session offers the
/// field) or a label ladder (`MonitorValueDrum`).
public struct LadderTab<Key: Equatable & Sendable>: Sendable {
    public let label: String
    public let key: Key
    public let ladder: CaptureLadder
    public let detail: String?
    public let activate: LadderWrite<Key>?
    public let applyOnActivate: Bool
    public let disabled: Bool
    public let setting: CaptureLadderSetting?
    public let tint: CaptureTint?
    public let values: (@Sendable (String) -> [String])?
    public let steps: (@Sendable (String) -> (LadderStep, LadderStep)?)?
    /// Spoken on the drum when it carries steps: what the buttons beside the value do.
    public let stepsHint: String?

    public init(
        label: String, key: Key, ladder: CaptureLadder, detail: String? = nil,
        activate: LadderWrite<Key>? = nil, applyOnActivate: Bool = true, disabled: Bool = false,
        setting: CaptureLadderSetting? = nil, tint: CaptureTint? = nil,
        values: (@Sendable (String) -> [String])? = nil,
        steps: (@Sendable (String) -> (LadderStep, LadderStep)?)? = nil,
        stepsHint: String? = nil
    ) {
        self.label = label
        self.key = key
        self.ladder = ladder
        self.detail = detail
        self.activate = activate
        self.applyOnActivate = applyOnActivate
        self.disabled = disabled
        self.setting = setting
        self.tint = tint
        self.values = values
        self.steps = steps
        self.stepsHint = stepsHint
    }
}

public struct LadderSheetPresentation<Key: Equatable & Sendable>: Sendable {
    public let title: String
    public let subtitle: String
    public let tabs: [LadderTab<Key>]
    public let initialTab: Int
    public let lock: CaptureLock?
    public let lockBanner: String?

    public init(
        title: String, subtitle: String, tabs: [LadderTab<Key>], initialTab: Int = 0,
        lock: CaptureLock? = nil, lockBanner: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tabs = tabs
        self.initialTab = initialTab
        self.lock = lock
        self.lockBanner = lockBanner
    }
}
