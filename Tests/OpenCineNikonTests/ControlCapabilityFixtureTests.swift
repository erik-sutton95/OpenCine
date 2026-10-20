import Foundation
import OpenCineCameraVocabulary
import OpenCineCore
import Testing

@testable import OpenCineNikon

/// What a Nikon Z body offers through the one control model (the controls the Z app offers today),
/// exported to `Fixtures/control-capabilities-nikon.tsv`, which the Kotlin
/// `ControlCapabilityFixtureTest` and `tools/parity-metrics.py` read. After an intended change,
/// regenerate with `OPENCINE_WRITE_FIXTURES=1 swift test --filter ControlCapabilityFixtureTests`.
@MainActor
@Suite struct NikonControlCapabilityFixtureTests {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/control-capabilities-nikon.tsv")

    /// A ZR in movie mode, exposure M, H.265 at 25p, idle, with its shutter and aperture lists read.
    static func movie() -> NikonControlFacts {
        var facts = NikonCameraSessionTests.movieFacts()
        facts.reported = PTPCameraPropertySnapshot(
            iso: 800, isoAuto: false, exposureMode: "M", shutterMode: .speed, shutterSpeed: "1/50",
            fNumber: "f/2.8", wbMode: "Auto", wbKelvin: 5560, resolution: "3840x2160", fps: 25,
            fileType: "H.265 10-bit MOV", batteryPercent: 80, captureSelector: .video)
        facts.shutterLabels = ["1/50", "1/100"]
        facts.apertureLabels = ["f/2.8", "f/4"]
        return facts
    }

    static func controls(_ facts: NikonControlFacts) -> ControlCapabilities {
        let session = NikonCameraSession(driver: NikonCameraSessionTests.Driver(facts), serialNumber: "SIMULATED")
        session.refresh()
        return session.controlCapabilities()
    }

    @Test func zrOffersTodaysControls() {
        let controls = Self.controls(Self.movie())
        #expect(controls.offered == [
            .iso, .shutter, .whiteBalance, .iris, .focus, .tapFocus, .codecColor, .recordingFormat,
            .audio, .recording, .photo, .media, .mediaDelete, .multiview,
        ])
        // No motion service: gimbal and head tracking are not applicable, nor is ND.
        #expect(controls.gimbal.support == .unsupported)
        #expect(controls.headTracking.support == .unsupported)
        #expect(controls.ndFilter.support == .unsupported)
        // Lens- and body-dependent: zoom stays unknown, never false.
        #expect(controls.zoom.support == .unknown)
        #expect(controls.timecode.isShown)
        #expect(controls.timecode.offer == .frames(rate: Rational(25), dropFrame: nil))
    }

    /// The ten-section layout as a view of the model: no gimbal, no head tracking, no zoom section.
    @Test func layoutIsAViewOfTheModel() {
        let layout = MonitorLayoutCapabilities(controls: Self.controls(Self.movie()))
        #expect(!layout.gimbal && !layout.headTracking && !layout.zoom)
        #expect(layout.focus && layout.iris && layout.audio && layout.timecode)
    }

    @Test func fixtureMatchesSwift() throws {
        let rendered = ControlCapabilityVectors.document(integration: "nikon",
            bodies: [("ZR movie", Self.controls(Self.movie()))])
        if ProcessInfo.processInfo.environment["OPENCINE_WRITE_FIXTURES"] == "1" {
            try rendered.write(to: Self.fixture, atomically: true, encoding: .utf8)
        }
        #expect(try String(contentsOf: Self.fixture, encoding: .utf8) == rendered)
    }

    /// A Z body has no shooting-mode readout, so the header accent sits on the codec.
    @Test func theHeaderAccentsTheCodec() {
        #expect(Self.controls(Self.movie()).headerAccent == .codec)
    }
}
