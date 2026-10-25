import Testing

@testable import OpenCineCameraControls
import OpenCineCameraVocabulary
import OpenCineMedia

/// Owner style rule: operator copy never uses the em dash. Kotlin twin: `SharedCopyEmDashTest`.
struct SharedCopyEmDashTests {
    @Test func sharedOperatorCopyHasNoEmDash() {
        let copy = [
            ControlHud.recordingColorLockNote,
            MonitorConformPreview.Availability.variableRate.unavailableReason ?? "",
            MonitorSettingsCopy.cacheFullResolution, MonitorSettingsCopy.joystickSensitivity,
        ]
        for text in copy { #expect(!text.contains("\u{2014}"), "\(text)") }
    }
}
