import Foundation
import OpenCineMedia

/// What the shared playback screen says to the operator and to assistive technologies: control
/// labels, their values and hints, the clip information sheet and the deletion confirmation.
///
/// The SwiftUI screen (`MonitorUI`) reads it here; Compose keeps the twin `MonitorPlaybackCopy`
/// in `Android/monitor-ui`. Nothing links the two, so `Fixtures/playback-copy.tsv` lists every
/// string and both platforms' tests read it (`MonitorPlaybackCopyVectorTests`,
/// `MonitorPlaybackCopyVectorTest`): a label edited on one side only fails a test.
///
/// One accepted platform difference: `hideControlsHint` is read only on iOS, as the hide
/// control's accessibility hint. Compose has no hint semantics; TalkBack builds its own usage
/// hint from the click action, so Android carries the string but does not show it.
public enum MonitorPlaybackCopy {
    // Header chrome.
    public static let backToMedia = "Back to media"
    public static let favorite = "Favorite clip"
    public static let clipInformation = "Clip information"
    public static let share = "Share clip"
    public static let shareTitle = "SHARE"
    public static let delete = "Delete clip from camera"

    // Clip information sheet.
    public static let clipInformationTitle = "CLIP INFO"
    public static let closeClipInformation = "Close clip information"

    // Deletion confirmation, when the host supplies no captured copy of its own.
    public static let deleteConfirmationTitle = "Delete this clip from the camera?"
    public static let deleteConfirm = "Delete"
    public static let deleteCancel = "Cancel"
    public static let deleteCancelDescription = "Cancel deletion"
    public static let deleteConfirmDescription = "Delete from the camera card"

    // Transport.
    public static let backFifteen = "Back 15 seconds"
    public static let forwardFifteen = "Forward 15 seconds"
    public static let play = "Play"
    public static let pause = "Pause"
    public static let restart = "Restart clip"
    public static let previousClip = "Previous clip"
    public static let nextClip = "Next clip"

    // Options.
    public static let conformPreview = "Conform preview"
    public static let closeConformPreview = "Close conform preview"
    public static let mute = "Mute"
    public static let unmute = "Unmute"
    public static let loop = "Loop playback"
    public static let on = "On"
    public static let off = "Off"
    public static let hideControls = "Hide playback controls"
    /// iOS only (see the type's note): Compose has no accessibility hint.
    public static let hideControlsHint = "A restore control stays in the corner"
    public static let showControls = "Show playback controls"

    // Conform preview panel.
    public static let conformTitle = "CONFORM PREVIEW"
    /// The drum's first choice: play as recorded.
    public static let realTime = "Real time"

    // Scrubber. The gesture well over the picture has no label on either platform: a screen
    // reader cannot act on it.
    public static let position = "Playback position"

    // Rating shade.
    public static let showRating = "Show star rating"
    public static let hideRating = "Hide star rating"

    /// The one transport button: restart after the end, else pause while playing, else play.
    public static func transport(reachedEnd: Bool, playing: Bool) -> String {
        reachedEnd ? restart : playing ? pause : play
    }

    public static func muteToggle(muted: Bool) -> String { muted ? unmute : mute }

    /// The value read with a toggle's label (the loop chip).
    public static func toggleValue(_ on: Bool) -> String { on ? Self.on : off }

    /// The scrubber's value: whole seconds, never negative; an unknown position reads 0.
    public static func positionValue(seconds: Double) -> String {
        let whole = seconds.isFinite ? Int(max(0, seconds)) : 0
        return "\(whole) seconds"
    }

    /// The conform panel's line under its title: the clip's capture rate, leading into the choices.
    public static func conformSubtitle(captureRate: Double) -> String {
        MonitorConformPreview.menuHeader(captureRate: captureRate)
    }

    public static func rating(expanded: Bool) -> String { expanded ? hideRating : showRating }

    /// One star choice of the rating control.
    public static func rate(_ level: Int) -> String {
        "Rate \(level) \(level == 1 ? "star" : "stars")"
    }
}
