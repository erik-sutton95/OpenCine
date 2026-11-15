import Foundation

/// One category of the Multiview camera settings popup's rail, in the order the popup offers them.
/// The app maps each to its own controls. A later category is added on both twins; a host that
/// maps categories by `rawValue` (an optional lookup, showing nothing for one it lacks) keeps
/// compiling, while one with an exhaustive `switch` adds its case in the same change. Kotlin twin:
/// `MultiviewSettingsCategory`.
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

    public init(
        categories: [MultiviewSettingsCategory], recording: Bool = false, note: String? = nil
    ) {
        self.categories = categories
        self.recording = recording
        self.note = note
    }
}

extension MultiviewTool {
    /// The shared screen's toolbar, in Pocket iOS order. Kotlin twin: `MultiviewTool.SCREEN`.
    public static let screen: [MultiviewTool] = [.layout, .camera, .fit, .lut]
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
    /// The Add camera list's footer: cameras the app moves onto `network` (approved on the camera
    /// where `asksApproval`), or cameras already there (this phone's network when it has no name).
    public static func pickerFooter(
        network: String, commissioned: Bool, asksApproval: Bool = true
    ) -> String {
        if commissioned {
            return "Each camera will join \(network)."
                + (asksApproval ? " Approve on the camera if asked." : "")
        }
        return network.isEmpty
            ? "Cameras on this phone\u{2019}s network appear here."
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
