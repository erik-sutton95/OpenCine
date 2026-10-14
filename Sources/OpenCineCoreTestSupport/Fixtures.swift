import Foundation
import OpenCineCore

private func choices<T>(_ values: [T], _ make: (T) -> SettingValue) -> SettingDomain {
    SettingDomain(choices: values.map(make))
}

private let thirds = (-9...9).map { SettingValue.exposureCompensation(Rational($0, 3)) }

extension FakeCameraSession {
    /// DJI-like: raw status mode bytes map to common modes whose domains differ, recording is a
    /// toggle on the wire, every change is confirmed by the next status push 0.5 s later, and
    /// video modes report timecode and live audio levels (photo mode reports neither).
    public static func djiLike() -> FakeCameraSession {
        let video = CaptureMode(role: .video, id: "test.dji-like.video", title: "Video")
        let slow = CaptureMode(role: .video, id: "test.dji-like.slow-motion", title: "Slow Motion")
        let photo = CaptureMode(role: .photo, id: "test.dji-like.photo", title: "Photo")
        let iso = SettingDescriptor(
            .iso, domain: choices([100, 200, 400, 800, 1600, 3200]) { .iso(.manual($0)) })
        let ev = SettingDescriptor(.exposureCompensation, domain: SettingDomain(choices: thirds))
        let wb = SettingDescriptor(
            .whiteBalance,
            domain: SettingDomain(choices: [.whiteBalance(.auto)], range: 2000...10000, step: 100))
        let zoom = SettingDescriptor(.zoom, domain: SettingDomain(range: 1...4, step: 0.1))
        func shutter(_ denominators: [Int]) -> SettingDescriptor {
            var domain = choices(denominators) { .shutter(.duration(Rational(1, $0))) }
            domain.choices.insert(.shutter(.auto), at: 0)
            return SettingDescriptor(.shutter, domain: domain)
        }
        func fps(_ rates: [Int]) -> SettingDescriptor {
            SettingDescriptor(.frameRate, domain: choices(rates) { .frameRate(Rational($0)) })
        }
        let modes: [UInt8: FakeMode] = [
            0x01: FakeMode(
                video,
                [iso, shutter([50, 100, 200, 400]), ev, wb, fps([24, 25, 30, 48, 50, 60]), zoom,
                 SettingDescriptor(.recording)],
                unsupported: [.aperture], timecodeCapability: .supported(.seconds), audioLevels: .supported),
            0x02: FakeMode(
                slow,
                [iso, shutter([250, 500, 1000]), ev, wb, fps([120, 240]), zoom,
                 SettingDescriptor(.recording)],
                unsupported: [.aperture], timecodeCapability: .supported(.seconds), audioLevels: .supported),
            0x05: FakeMode(
                photo,
                [iso, shutter([50, 100, 200, 400]), ev, wb, zoom,
                 SettingDescriptor(.recording, availability: .unavailable(.mode))],
                unsupported: [.aperture, .frameRate], timecodeCapability: .unsupported,
                audioLevels: .unsupported),
        ]
        return FakeCameraSession(
            behavior: FakeCameraBehavior(
                integration: IntegrationID("test.dji-like"), reportDelay: .milliseconds(500),
                observationTimeout: .seconds(2), recordWire: .toggle, modes: modes),
            device: FakeDevice(
                rawMode: 0x01,
                settings: [
                    .iso(.manual(800)), .shutter(.duration(Rational(1, 50))),
                    .exposureCompensation(Rational(0)), .whiteBalance(.kelvin(5600)),
                    .frameRate(Rational(24)), .zoom(1),
                ],
                batteryPercent: 76, freeBytes: 64_000_000_000,
                timecode: CameraTimecode(hours: 1, minutes: 2, seconds: 3, frames: 4),
                audioLevels: AudioLevels(
                    left: .init(level: -20, peak: -12), right: .init(level: -18, peak: -10))))
    }

    /// Nikon-like: shutter in native angle mode, explicit record commands that need the camera's
    /// own live view, an acknowledgement-only focus point, control that does not depend on
    /// which picture is displayed, and audio levels without held peaks.
    public static func nikonLike() -> FakeCameraSession {
        var iso = choices([100, 200, 400, 800, 1600, 3200, 6400]) { SettingValue.iso(.manual($0)) }
        iso.choices.append(.iso(.autoLimited(maximum: 6400)))
        var wb = choices(["daylight", "cloudy", "tungsten"]) { .whiteBalance(.preset($0)) }
        wb.choices.insert(.whiteBalance(.auto), at: 0)
        wb.range = 2500...10000
        wb.step = 10
        let movie = FakeMode(
            CaptureMode(role: .video, id: "test.nikon-like.movie", title: "Movie"),
            [
                SettingDescriptor(.iso, domain: iso),
                SettingDescriptor(
                    .shutter, domain: choices([45.0, 90, 180, 270, 360]) { .shutter(.angle($0)) }),
                SettingDescriptor(.aperture, domain: choices([2.8, 4, 5.6, 8, 11]) { .aperture($0) }),
                SettingDescriptor(.exposureCompensation, domain: SettingDomain(choices: thirds)),
                SettingDescriptor(.whiteBalance, domain: wb),
                SettingDescriptor(
                    .frameRate,
                    domain: SettingDomain(choices: [
                        .frameRate(Rational(24000, 1001)), .frameRate(Rational(24)),
                        .frameRate(Rational(25)), .frameRate(Rational(30000, 1001)),
                        .frameRate(Rational(50)),
                    ])),
                SettingDescriptor(
                    .focusMode, domain: choices([FocusMode.single, .continuous, .manual]) {
                        .focusMode($0)
                    }),
                SettingDescriptor(
                    .focusPoint, semantics: SettingSemantics(confirmation: .acknowledgementOnly)),
                SettingDescriptor(.recording),
            ],
            unsupported: [.zoom], timecodeCapability: .supported(.frames(rate: Rational(24), dropFrame: false)),
            audioLevels: .supported)
        return FakeCameraSession(
            behavior: FakeCameraBehavior(
                integration: IntegrationID("test.nikon-like"), reportDelay: .milliseconds(200),
                observationTimeout: .seconds(3), recordWire: .explicit, recordNeedsLiveView: true,
                modes: [0x01: movie]),
            device: FakeDevice(
                rawMode: 0x01,
                settings: [
                    .iso(.manual(400)), .shutter(.angle(180)), .aperture(4),
                    .exposureCompensation(Rational(0)), .whiteBalance(.preset("daylight")),
                    .frameRate(Rational(24)), .focusMode(.continuous),
                ],
                batteryPercent: 90, freeBytes: 128_000_000_000,
                timecode: CameraTimecode(hours: 10, minutes: 0, seconds: 0, frames: 0, dropFrame: false),
                audioLevels: AudioLevels(left: .init(level: -30), right: .init(level: -31))))
    }

    /// Luna-like: settings settle for 2.5 s before readback, an accepted write may not stick,
    /// the fixed aperture is read-only, storage is never reported, timecode is time of day derived
    /// from a clock, and there are no live audio levels.
    public static func lunaLike() -> FakeCameraSession {
        var iso = choices([100, 200, 400, 800, 1600, 3200, 6400]) { SettingValue.iso(.manual($0)) }
        iso.choices.insert(.iso(.auto), at: 0)
        var shutter = choices([30, 60, 120, 240]) { SettingValue.shutter(.duration(Rational(1, $0))) }
        shutter.choices.insert(.shutter(.auto), at: 0)
        let video = FakeMode(
            CaptureMode(role: .video, id: "test.luna-like.video", title: "Video"),
            [
                SettingDescriptor(.iso, domain: iso),
                SettingDescriptor(.shutter, domain: shutter),
                SettingDescriptor(.aperture, access: .readOnly, domain: choices([2.0]) { .aperture($0) }),
                SettingDescriptor(
                    .exposureCompensation,
                    domain: SettingDomain(choices: (-6...6).map { .exposureCompensation(Rational($0, 3)) })),
                SettingDescriptor(
                    .whiteBalance,
                    domain: SettingDomain(choices: [.whiteBalance(.auto)], range: 2700...6500, step: 100)),
                SettingDescriptor(.frameRate, domain: choices([24, 30, 60]) { .frameRate(Rational($0)) }),
                SettingDescriptor(.zoom, domain: SettingDomain(range: 1...2, step: 0.1)),
                SettingDescriptor(
                    .focusMode, domain: choices([FocusMode.single, .continuous]) { .focusMode($0) }),
                SettingDescriptor(.recording),
            ],
            unsupported: [], timecodeCapability: .supported(.seconds), audioLevels: .unsupported)
        return FakeCameraSession(
            behavior: FakeCameraBehavior(
                integration: IntegrationID("test.luna-like"), reportDelay: .milliseconds(2500),
                observationTimeout: .seconds(6), recordWire: .explicit, modes: [0x01: video],
                timecodeOrigin: .clockDerived),
            device: FakeDevice(
                rawMode: 0x01,
                settings: [
                    .iso(.manual(200)), .shutter(.duration(Rational(1, 60))), .aperture(2),
                    .exposureCompensation(Rational(0)), .whiteBalance(.kelvin(4000)),
                    .frameRate(Rational(30)), .zoom(1), .focusMode(.continuous),
                ],
                batteryPercent: 55,
                timecodeReading: CameraTimecodeReading(hours: 9, minutes: 30, seconds: 0)))
    }
}

/// A picture with no camera behind it: a capture device, a relay picture or a replay. It only
/// ever changes picture state.
public struct FakePictureSource: Sendable {
    public private(set) var descriptor: PictureSourceDescriptor
    public private(set) var health = PictureHealth.starting

    public init(label: String) { descriptor = PictureSourceDescriptor(label: label) }

    public mutating func start() { health = .live }
    public mutating func fail() { health = .failed }
}

public enum FakeEntries {
    /// Picture only: no camera control and no telemetry.
    public static func captureOnly(_ picture: PictureSourceDescriptor) -> MonitorEntryDescriptor {
        MonitorEntryDescriptor(
            name: picture.label, picture: picture, controlAuthority: .unavailable(.route))
    }

    /// Camera control and telemetry with no picture.
    public static func controlOnly(_ session: CameraSessionID, name: String) -> MonitorEntryDescriptor {
        MonitorEntryDescriptor(
            name: name, cameraSession: session, telemetry: .cameraSession, controlAuthority: .owner)
    }
}
