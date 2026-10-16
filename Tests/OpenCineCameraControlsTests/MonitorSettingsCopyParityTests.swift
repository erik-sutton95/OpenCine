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
}
