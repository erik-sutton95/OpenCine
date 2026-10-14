import Foundation
import MonitorPresentation
import Observation
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

@testable import OpenCineAppKit

/// A5-02, A5-03: one formatter follows the precision the source declares. SIMULATED sources;
/// Kotlin mirrors the same names in `TimecodePrecisionTest`.
@MainActor
@Suite struct TimecodePrecisionTests {
    private let value = CameraTimecode(hours: 1, minutes: 2, seconds: 3, frames: 17)

    @Test func framesShowOnlyUnderADeclaredFramePrecision() {
        let frames = TimecodePrecision.frames(rate: Rational(24), dropFrame: nil)
        #expect(MonitorTimecodeFormat.label(value, precision: frames) == "01:02:03:17")
        #expect(MonitorTimecodeFormat.label(value, precision: .seconds) == "01:02:03")
        #expect(MonitorTimecodeFormat.label(value, precision: nil) == "01:02:03",
            "an undeclared precision never shows a frame field")
        let secondsOnly = CameraTimecodeReading(hours: 1, minutes: 2, seconds: 3)
        #expect(MonitorTimecodeFormat.label(secondsOnly, precision: frames) == "01:02:03",
            "a missing frame count is never derived")
    }

    @Test func dropFrameFollowsTheValueThenTheDeclaration() {
        let declared = TimecodePrecision.frames(rate: Rational(30000, 1001), dropFrame: true)
        #expect(MonitorTimecodeFormat.label(value, precision: declared) == "01:02:03;17")
        var nonDrop = value
        nonDrop.dropFrame = false
        #expect(MonitorTimecodeFormat.label(nonDrop, precision: declared) == "01:02:03:17")
    }

    /// A5-13: the empty clock follows the declaration too: a frame-counting source keeps its
    /// frame field, seconds and undeclared sources show seconds. No surface hard-codes one.
    @Test func placeholderFollowsTheDeclaredPrecision() {
        #expect(MonitorTimecodeFormat.placeholder(.frames(rate: Rational(25), dropFrame: nil)) == "--:--:--:--")
        #expect(MonitorTimecodeFormat.placeholder(.seconds) == "--:--:--")
        #expect(MonitorTimecodeFormat.placeholder(nil) == "--:--:--")
        let empty = MonitorStatusPresentation(recording: nil, timecodePlaceholder: "--:--:--:--")
        #expect(empty.clock == "--:--:--:--")
        #expect(MonitorStatusPresentation(recording: nil, timecode: "01:02:03").clock == "01:02:03")
    }

    @available(macOS 14, *)
    @Test(arguments: [("dji", "--:--:--"), ("nikon", "--:--:--:--"), ("luna", "--:--:--")])
    func statusPlaceholderFollowsEachSourceDeclaration(source: String, placeholder: String) async throws {
        let camera: FakeCameraSession =
            switch source {
            case "dji": .djiLike()
            case "nikon": .nikonLike()
            default: .lunaLike()
            }
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        #expect(await eventually { control.statusPresentation().timecodePlaceholder == placeholder })
    }

    @Test func capabilityKeepsPrecisionOnlyWhileSupported() {
        #expect(TimecodeCapability(support: .unknown, precision: .seconds).precision == nil)
        #expect(TimecodeCapability.unsupported.precision == nil)
        #expect(TimecodeCapability.supported(.seconds).precision == .seconds)
    }

    @available(macOS 14, *)
    @Test(arguments: [("dji", "01:02:03"), ("nikon", "10:00:00:00"), ("luna", "09:30:00")])
    func statusClockFollowsEachSourceDeclaration(source: String, label: String) async throws {
        let camera: FakeCameraSession =
            switch source {
            case "dji": .djiLike()
            case "nikon": .nikonLike()
            default: .lunaLike()
            }
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        #expect(await eventually { control.statusPresentation().timecode == label })
    }

    @available(macOS 14, *)
    @Test func aTimecodeOnlyReportDoesNotInvalidateSnapshotReaders() async throws {
        let camera = FakeCameraSession.nikonLike()
        await camera.cameraReportsStatus()
        let control = MonitorControlModel()
        control.bind(camera)
        #expect(await eventually { control.timecode.value?.frames == 0 })
        let snapshotRead = ObservationFlag()
        withObservationTracking { _ = control.snapshot } onChange: { snapshotRead.fired = true }
        let timecodeRead = ObservationFlag()
        withObservationTracking { _ = control.timecode } onChange: { timecodeRead.fired = true }
        await camera.cameraReportsTimecode(CameraTimecode(hours: 10, minutes: 0, seconds: 0, frames: 1))
        #expect(await eventually { control.statusPresentation().timecode == "10:00:00:01" })
        #expect(timecodeRead.fired)
        #expect(!snapshotRead.fired, "a per-frame counter re-renders the clock only")
        #expect(control.snapshot?.timecode.value?.frames == 1, "the stored snapshot is still current")
        _ = await camera.loseLink()
        #expect(await eventually { snapshotRead.fired }, "any other change still notifies")
    }
}

private final class ObservationFlag: @unchecked Sendable {
    var fired = false
}
