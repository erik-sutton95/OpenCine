import Foundation

/// One category of the Multiview camera settings popup's rail, in the order the popup offers them.
/// The app maps each to its own controls. Kotlin twin: `MultiviewSettingsCategory`.
public enum MultiviewSettingsCategory: String, CaseIterable, Hashable, Sendable {
    case iso, shutter, exposure, wb, focus, aperture, mode, resolution, color, audio

    /// The rail's name for it (the tabs show it upper-cased).
    public var title: String {
        switch self {
        case .wb: "WB"
        case .resolution: "Format"
        default: rawValue.capitalized
        }
    }

    /// The rail tab's accessibility identifier.
    public var identifier: String { "multiview.settings.control." + rawValue }

    /// What a camera offers now, from its capabilities: focus mode and aperture where it has them;
    /// format, color and (where it has audio controls) audio only in a video mode.
    public static func offered(focus: Bool, aperture: Bool, photo: Bool, audio: Bool) -> [Self] {
        var result: [Self] = [.iso, .shutter, .exposure, .wb]
        if focus { result.append(.focus) }
        if aperture { result.append(.aperture) }
        result.append(.mode)
        if !photo {
            result += [.resolution, .color]
            if audio { result.append(.audio) }
        }
        return result
    }

    /// Whether the category is read-only now: mode, format and color while the camera records.
    public func locked(recording: Bool) -> Bool {
        recording && [.mode, .resolution, .color].contains(self)
    }
}

/// The app's open settings editor on one camera, as the popup shows it. Kotlin twin:
/// `MultiviewCameraSettingsState`.
public struct MultiviewCameraSettingsState: Hashable, Sendable {
    /// The categories this camera offers now (`MultiviewSettingsCategory.offered`).
    public var categories: [MultiviewSettingsCategory]
    /// The camera records: mode, format and color are locked.
    public var recording: Bool
    /// The editor's last command note (a refusal or error), nil when there is none.
    public var note: String?
    /// The editor has described the camera once; the controls start again when it first does.
    public var described: Bool

    public init(
        categories: [MultiviewSettingsCategory], recording: Bool = false, note: String? = nil,
        described: Bool = true
    ) {
        self.categories = categories
        self.recording = recording
        self.note = note
        self.described = described
    }
}

extension MultiviewNetworkRestore {
    /// What the stage shows while it closes.
    public var closingProgress: String {
        switch self {
        case .none: "Closing Multiview\u{2026}"
        case .cameraNetworks: "Returning cameras to their Wi-Fi\u{2026}"
        }
    }
}

extension MultiviewCopy {
    /// The Add camera list's footer: cameras the app moves onto `network`, or cameras already there.
    public static func pickerFooter(network: String, commissioned: Bool) -> String {
        commissioned
            ? "Each camera will join \(network). Approve on the camera if asked."
            : "Cameras already on \(network) appear here."
    }
    /// A listed camera that joins without its picture.
    public static let previewUnavailable = "Try experimental shared Wi-Fi \u{00B7} Preview unavailable"
    public static let reconnectBeforeSettings = "Reconnect this camera before changing settings."
    public static let waitingForControls = "Waiting for camera controls\u{2026}"
    public static let controlsUnavailable = "Controls unavailable"
    public static let lockedWhileRecording = "Locked while recording"
    public static let cameraSettings = "Camera settings"
}
