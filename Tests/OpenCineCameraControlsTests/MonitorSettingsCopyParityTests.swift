import Foundation
import Testing

@testable import OpenCineCameraControls

/// A2-37: the automatic-reports disclosure is one text on every platform, and it names what the
/// shared reporter sends (crashes, hangs, live-feed reports, session health counts, no images).
struct MonitorSettingsCopyParityTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func automaticReportsIsTheSameDisclosureOnAndroid() throws {
        let kotlin = try String(contentsOf: Self.root.appending(path:
            "Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/MonitorSettingsCopy.kt"),
            encoding: .utf8)
        #expect(kotlin.contains("\"\(MonitorSettingsCopy.automaticReports)\""))
        #expect(kotlin.contains("\"\(MonitorSettingsCopy.keepScreenAwake)\""))
    }

    /// A2-31: one HDR display help for every app; only the camera mode it is not differs.
    @Test func hdrPanelHelpIsSharedAndNamesTheCameraModeItIsNot() {
        let pocket = MonitorSettingsCopy.hdrPanel(cameraMode: "HDR/HLG color mode")
        #expect(pocket.hasPrefix("Outdoor panel brightness, not a grade."))
        #expect(pocket.contains("still read the decoded camera signal, so judge exposure there"))
        #expect(pocket.contains("This is not the camera's HDR/HLG color mode. Off by default."))
        #expect(!pocket.contains("\u{2014}"))
    }

    /// A2-78: the Feed Upscaler help is one text, on Android too.
    @Test func feedUpscalerHelpIsTheSameOnAndroid() throws {
        let kotlin = try String(contentsOf: Self.root.appending(path:
            "Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/MonitorSettingsCopy.kt"),
            encoding: .utf8)
        let escaped = MonitorSettingsCopy.feedUpscaler.replacingOccurrences(of: "\n", with: "\\n")
        #expect(kotlin.contains("\"\(escaped)\""))
        #expect(MonitorSettingsCopy.feedUpscaler.hasPrefix("How the live-view frame is enlarged to fill the panel."))
        #expect(!MonitorSettingsCopy.feedUpscaler.contains("\u{2014}"))
    }

    @Test func automaticReportsNamesEverythingTheReporterSends() {
        for part in ["crash", "hang", "live-feed reports", "session health counts", "exclude all images",
            "No footage or GPS location", "See Reporting Privacy"] {
            #expect(MonitorSettingsCopy.automaticReports.contains(part), "\(part)")
        }
    }

    /// The bundled privacy texts of every app read the reliability-report paragraph from here, so
    /// it states the same facts as the websites: the random install identifier made on opt-in and
    /// deleted on opt-out, and the toggle's place in Operator Setup > System.
    @Test func reliabilityReportsPrivacyIsOneTextOnEveryPlatform() throws {
        let kotlin = try String(contentsOf: Self.root.appending(path:
            "Android/camera-controls/src/main/kotlin/com/opencapture/opencine/cameracontrols/MonitorSettingsCopy.kt"),
            encoding: .utf8)
        let escaped = MonitorSettingsCopy.reliabilityReportsPrivacy.replacingOccurrences(of: "\n", with: "\\n")
        #expect(kotlin.contains("\"\(escaped)\""))
        for part in ["Optional reliability reports\n", "through Sentry",
            "random install identifier that is created when you opt in and deleted when you opt out",
            "Operator Setup > System", "deletes the install identifier", "exclude all images"] {
            #expect(MonitorSettingsCopy.reliabilityReportsPrivacy.contains(part), "\(part)")
        }
        #expect(!MonitorSettingsCopy.reliabilityReportsPrivacy.contains("\u{2014}"))
    }
}
