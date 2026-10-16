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
