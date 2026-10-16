import Foundation
import OpenCineCore
import OpenCineMotion
import Testing

@testable import OpenCineDJI

/// What each DJI body offers through the one control model, pinned per body (the controls the
/// Pocket app offers today), and exported to `Fixtures/control-capabilities-dji.tsv`, which the
/// Kotlin `ControlCapabilityFixtureTest` and `tools/parity-metrics.py` read. After an intended
/// change, regenerate with `OPENCINE_WRITE_FIXTURES=1 swift test --filter ControlCapabilityFixtureTests`.
@MainActor
@Suite struct ControlCapabilityFixtureTests {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/control-capabilities-dji.tsv")

    /// Bodies in export order.
    static let bodies: [(Int, String)] = [
        (0x0022, "Osmo Pocket 4 Pro"), (0x0021, "Osmo Pocket 4"), (0x0020, "Osmo Pocket 3"),
        (0x0019, "Osmo Nano"), (0x0018, "Osmo Action 6"), (0x0015, "Osmo Action 5 Pro"),
        (0x0014, "Osmo Action 4"), (0x0017, "Osmo 360"),
    ]

    /// A linked, idle body in video mode, manual exposure, with its capture port reporting a
    /// shutter list: the state the live screen reads.
    static func controls(_ id: Int, _ name: String) -> ControlCapabilities {
        let port = FakePort()
        port.connectedModel = CameraModel.resolve(modelId: id, name: name)
        port.status.expoMode = .manual
        port.status.availableShutterDenoms = [50, 100]
        port.captureControlState = DJICaptureControlState(reported: port.status, model: port.connectedModel)
        let seam = DJICameraSessionAdapter(session: port)
        return seam.controlCapabilities()
    }

    static let common: Set<ControlFamily> = [
        .iso, .shutter, .whiteBalance, .tint, .exposureCompensation, .codecColor, .recordingFormat,
        .audio, .recording, .photo, .media, .mediaDelete,
    ]

    @Test func eachBodyOffersTodaysControls() {
        let pocket = Self.common.union([.focus, .tapFocus, .zoom, .gimbal, .headTracking, .multiview])
        let expected: [String: Set<ControlFamily>] = [
            "Osmo Pocket 4 Pro": pocket, "Osmo Pocket 4": pocket, "Osmo Pocket 3": pocket,
            // Nano: no gimbal, fixed 1x, no AF; Multi View lists it with a preview.
            "Osmo Nano": Self.common.union([.multiview]),
            // Action 6: the variable-iris strategy panel; Multi View only as an experiment.
            "Osmo Action 6": Self.common.union([.iris]),
            "Osmo Action 5 Pro": Self.common, "Osmo Action 4": Self.common, "Osmo 360": Self.common,
        ]
        for (id, name) in Self.bodies {
            let controls = Self.controls(id, name)
            #expect(controls.offered == expected[name], "\(name)")
            // Never claimed for an Osmo body: ND and face metering are not declared support.
            #expect(controls.ndFilter.support == .unsupported, "\(name)")
            #expect(controls.faceMetering.support == .unknown, "\(name)")
            // Readouts: every body but Nano reports timecode; every body reports audio levels.
            #expect(controls.timecode.isShown == (name != "Osmo Nano"), "\(name)")
            #expect(controls.liveAudioLevels.isShown, "\(name)")
        }
    }

    /// The ten-section layout is a computed view of the model and equals the integration's
    /// existing projection for every body.
    @Test func layoutIsAViewOfTheModel() {
        var base = MonitorLayoutCapabilities()
        base.clipDelete = true
        base.clipStar = true
        base.requiresInternetHop = true
        base.audio = true
        for (id, name) in Self.bodies {
            let port = FakePort()
            port.connectedModel = CameraModel.resolve(modelId: id, name: name)
            port.captureControlState = DJICaptureControlState(reported: port.status, model: port.connectedModel)
            let seam = DJICameraSessionAdapter(session: port)
            #expect(MonitorLayoutCapabilities(controls: seam.controlCapabilities(), base: base)
                == seam.layout(base: base), "\(name)")
            port.captureControlState = nil
            let legacy = DJICameraSessionAdapter(session: port)
            #expect(MonitorLayoutCapabilities(controls: legacy.controlCapabilities(), base: base)
                == legacy.layout(base: base), "\(name) without the capture port")
        }
    }

    /// Typed values ride with support: native ISO extensions, zoom stops and motion.
    @Test func offersCarryTheirValues() {
        let pro = Self.controls(0x0022, "Osmo Pocket 4 Pro")
        #expect(pro.zoom.offer?.stops == [1, 3, 6, 12])
        #expect(pro.gimbal.offer == .pocketGimbal)
        #expect(pro.timecode.offer == .seconds)
        #expect(pro.iso.offer?.autoRangeFloor == 100)
        #expect(pro.shutter.offer?.domain?.choices.count == 2)
        let nano = Self.controls(0x0019, "Osmo Nano")
        #expect(nano.zoom.offer == nil)
        #expect(nano.gimbal.offer == nil)
    }

    @Test func fixtureMatchesSwift() throws {
        let rendered = ControlCapabilityVectors.document(integration: "dji",
            bodies: Self.bodies.map { ($0.1, Self.controls($0.0, $0.1)) })
        if ProcessInfo.processInfo.environment["OPENCINE_WRITE_FIXTURES"] == "1" {
            try rendered.write(to: Self.fixture, atomically: true, encoding: .utf8)
        }
        #expect(try String(contentsOf: Self.fixture, encoding: .utf8) == rendered)
    }
}
