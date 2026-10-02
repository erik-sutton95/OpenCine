import Foundation

/// Stable navigation vocabulary for operator setup. Availability is an app-supplied value.
public enum MonitorSettingsTab: String, CaseIterable, Identifiable, Sendable {
    case link = "Link"
    case sharing = "Sharing"
    case assist = "View Assist"
    case controls = "Controls"
    case display = "Display"
    case storage = "Storage"
    case system = "System"

    public var id: String { rawValue }
    public var subtitle: String {
        switch self {
        case .link: "Connection state and link behavior."
        case .sharing: "Share this feed with devices on the same camera Wi-Fi."
        case .assist: "Behavior for live-view tools."
        case .controls: "Touch behavior and safety."
        case .display: "Live view buttons and chrome."
        case .storage: "Local cache and integrations."
        case .system: "App-level behavior."
        }
    }
    public var pill: String {
        switch self {
        case .link: "Live"
        case .sharing: "Share"
        case .assist: "Assist"
        case .controls: "Touch"
        case .display: "Visibility"
        case .storage: "Data"
        case .system: "App"
        }
    }
    public var rail: String {
        switch self {
        case .link: "Connection"
        case .sharing: "SHARE"
        case .assist: "Scopes & overlays"
        case .controls: "Dials and safety"
        case .display: "Live view"
        case .storage: "Cache & accounts"
        case .system: "App behavior"
        }
    }
}
