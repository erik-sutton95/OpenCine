import Foundation

/// Stages one screen with fake sources inside an app's production composition: the launch contract
/// the shared conformance kit (`OpenCineAppUITesting`) speaks to every app. Debug and simulator
/// only; each app decodes it in its existing review harness, which Release builds compile out.
/// The Kotlin twin (`com.opencapture.monitorui.ReviewLaunch`) has the same fields and keys.
public struct ReviewLaunch: Hashable, Sendable {
    public enum Screen: String, CaseIterable, Sendable {
        case cameras, pair, live, media, playback, settings
        case chromeEdit = "chrome-edit"
    }
    /// Where staged clips come from: the phone's own cache, or a connected camera's card.
    public enum Source: String, CaseIterable, Sendable { case local, camera }

    public var screen: Screen
    /// The app's cameras and pair page states (`empty`, `connecting`, `pair-join`, ...).
    public var state: String?
    public var layout: MonitorMediaLayout
    /// Enough clips by default to scroll an iPad landscape grid.
    public var mediaCount: Int
    public var source: Source
    /// A connected camera session, required for camera-only actions such as clip delete.
    public var connected: Bool
    public var settingsTab: MonitorSettingsTab?
    /// Writable simulated camera controls instead of the read-only native preview.
    public var commonControls: Bool
    /// The camera's metered exposure in stops, for example -2/3; nil while the camera reports none.
    public var meteredEV: Double?

    public init(
        screen: Screen, state: String? = nil, layout: MonitorMediaLayout = .grid, mediaCount: Int = 96,
        source: Source = .local, connected: Bool = false, settingsTab: MonitorSettingsTab? = nil,
        commonControls: Bool = true, meteredEV: Double? = nil
    ) {
        self.screen = screen
        self.state = state
        self.layout = layout
        self.mediaCount = mediaCount
        self.source = source
        self.connected = connected
        self.settingsTab = settingsTab
        self.commonControls = commonControls
        self.meteredEV = meteredEV
    }

    /// Wire keys: launch environment on iOS, intent string extras on Android.
    public enum Key {
        public static let screen = "OPV_UI_REVIEW_SCREEN"
        public static let state = "OPV_UI_REVIEW_STATE"
        public static let layout = "OPV_UI_REVIEW_MEDIA_LAYOUT"
        public static let mediaCount = "OPV_UI_REVIEW_MEDIA_COUNT"
        public static let source = "OPV_UI_REVIEW_MEDIA_SOURCE"
        public static let connected = "OPV_UI_REVIEW_CONNECTED"
        public static let settingsTab = "OPV_UI_REVIEW_SETTINGS_TAB"
        public static let commonControls = "OPV_UI_REVIEW_COMMON_CONTROLS"
        public static let meteredEV = "OPV_UI_REVIEW_METERED_EV"
    }

    public var environment: [String: String] {
        var values = [
            Key.screen: screen.rawValue, Key.layout: layout.rawValue, Key.mediaCount: String(mediaCount),
            Key.source: source.rawValue, Key.connected: connected ? "1" : "0",
            Key.commonControls: commonControls ? "1" : "0",
        ]
        values[Key.state] = state
        values[Key.settingsTab] = settingsTab?.rawValue
        values[Key.meteredEV] = meteredEV.map { String($0) }
        return values
    }

    /// Nil when no review is staged or a value is malformed: a typo must not stage a default.
    public init?(environment: [String: String]) {
        guard let screen = environment[Key.screen].flatMap(Screen.init(rawValue:)) else { return nil }
        func decode<Value>(_ key: String, _ fallback: Value, _ parse: (String) -> Value?) -> Value? {
            guard let raw = environment[key] else { return fallback }
            return parse(raw)
        }
        func flag(_ raw: String) -> Bool? { ["1": true, "0": false][raw] }
        // Optional fields: absent is nil, present but malformed rejects the launch.
        let settingsTab = environment[Key.settingsTab].map(MonitorSettingsTab.init(rawValue:))
        let meteredEV = environment[Key.meteredEV].map { Double($0).flatMap { $0.isFinite ? $0 : nil } }
        guard let layout = decode(Key.layout, .grid, MonitorMediaLayout.init(rawValue:)),
            let mediaCount = decode(Key.mediaCount, 96, { Int($0).flatMap { $0 > 0 ? $0 : nil } }),
            let source = decode(Key.source, .local, Source.init(rawValue:)),
            let connected = decode(Key.connected, false, flag),
            let commonControls = decode(Key.commonControls, true, flag),
            settingsTab != .some(nil), meteredEV != .some(nil)
        else { return nil }
        self.init(
            screen: screen, state: environment[Key.state], layout: layout, mediaCount: mediaCount,
            source: source, connected: connected, settingsTab: settingsTab ?? nil,
            commonControls: commonControls, meteredEV: meteredEV ?? nil)
    }

    /// The review this process was launched with, if any.
    public static var current: ReviewLaunch? { ReviewLaunch(environment: ProcessInfo.processInfo.environment) }
}
