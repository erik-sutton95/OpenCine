import Foundation

/// The common capture control's press, hold, look and spoken state, as values. `MonitorCaptureButton`
/// (SwiftUI) and its Compose twin draw it; keeping it portable lets every host test it.
///
/// `enabled` is the surface admission (unlocked, uncovered, not read-only). `busy` is the source
/// settling another command and `pending` a record request in flight: both make the control inert
/// for that window without the locked look.
public struct MonitorCapturePolicy: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case press, openMode }

    public let enabled: Bool
    public let busy: Bool
    public let pending: Bool
    public let photo: Bool
    /// A record editor exists: the recording state is known and this monitor may write it.
    public let canRecord: Bool
    public let recording: Bool?
    /// The source offers a shooting-mode sheet on a hold.
    public let offersMode: Bool

    public init(
        enabled: Bool, busy: Bool = false, pending: Bool, photo: Bool, canRecord: Bool,
        recording: Bool?, offersMode: Bool
    ) {
        self.enabled = enabled
        self.busy = busy
        self.pending = pending
        self.photo = photo
        self.canRecord = canRecord
        self.recording = recording
        self.offersMode = offersMode
    }

    private var lit: Bool { enabled && !busy }

    /// A tap records, stops or releases the still.
    public var pressAdmitted: Bool { lit && !pending && (photo || canRecord) }
    /// A hold opens the shooting-mode sheet, also before the camera reports whether it records.
    public var modeAdmitted: Bool { offersMode && lit && !pending }
    /// Either gesture can act, so the control takes touches.
    public var interactive: Bool { pressAdmitted || modeAdmitted }

    public var tapAction: Action? { pressAdmitted ? .press : nil }
    /// A source without a mode sheet records on a hold too: a press of any length is a press.
    public var holdAction: Action? {
        offersMode ? (modeAdmitted ? .openMode : nil) : tapAction
    }

    /// Only the locked (unadmitted) control dims to 40 %; a busy stop shows the softer 72 %.
    public var opacity: Double {
        guard enabled else { return 0.4 }
        return recording == true && (busy || pending) ? 0.72 : 1
    }

    public var accessibilityLabel: String {
        if photo { return "Take photo" }
        if recording == true { return pending ? "Stopping recording" : "Stop recording" }
        return recording == nil ? "Recording state unknown" : "Start recording"
    }

    /// What a hold does, for the screen reader; nil where a hold is a press.
    public var holdAccessibilityLabel: String? { offersMode ? "Shooting mode" : nil }

    /// Spoken beside the action, like the pre-shared Android record disc.
    public var stateDescription: String? {
        guard !photo, let recording else { return nil }
        return recording ? "Recording" : "Standby"
    }
}
