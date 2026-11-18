import Foundation
import OpenCineCore
import Testing

/// Saving and storing exposure and white balance presets. Kotlin mirror: `CameraSettingsPresetTest`,
/// same method names and the same stored text.
@Suite struct CameraSettingsPresetTests {
    private func snapshot(
        _ descriptors: [SettingDescriptor], _ values: [SettingValue],
        invalid: Set<SettingKey> = []
    ) -> CameraSnapshot {
        var snapshot = CameraSnapshot(session: CameraSessionID(), connection: .ready, authority: .owner)
        snapshot.capabilities = CapabilitySnapshot(descriptors: descriptors)
        for value in values {
            snapshot.settings[value.key] = ObservedValue(
                value, origin: .cameraReported, at: nil,
                validity: invalid.contains(value.key) ? .invalid(reason: "stale") : .valid)
        }
        return snapshot
    }

    @Test func captureKeepsOnlySettableReportedValuesInRecallOrder() throws {
        let reported = snapshot(
            [
                SettingDescriptor(.iso, domain: SettingDomain(choices: [.iso(.manual(800))])),
                SettingDescriptor(.shutter, domain: SettingDomain(choices: [.shutter(.angle(180))]),
                    availability: .unavailable(.mode)),
                SettingDescriptor(.aperture, access: .readOnly, domain: SettingDomain(choices: [.aperture(2)])),
                SettingDescriptor(.whiteBalance, domain: SettingDomain(range: 2000...10000, step: 100)),
                SettingDescriptor(.whiteBalanceTint, domain: SettingDomain(range: -10...10, step: 1)),
                SettingDescriptor(.exposureCompensation,
                    domain: SettingDomain(choices: [.exposureCompensation(Rational(1, 3))])),
                SettingDescriptor(.zoom, domain: SettingDomain(range: 1...2)),
            ],
            [
                .iso(.manual(800)), .shutter(.angle(180)), .aperture(2), .whiteBalance(.kelvin(5600)),
                .whiteBalanceTint(3), .exposureCompensation(Rational(2, 3)), .zoom(1.5),
            ],
            invalid: [.whiteBalanceTint])
        let preset = try #require(CameraSettingsPreset.capture(name: "Day", id: "a", from: reported))
        // Shutter is unavailable in this mode, aperture read-only, tint stale, EV off its domain
        // and zoom is not an exposure or white balance setting.
        #expect(preset.values == [.whiteBalance(.kelvin(5600)), .iso(.manual(800))])
        #expect(preset.name == "Day")
        #expect(CameraSettingsPreset.capture(name: "None", from: snapshot([], [.iso(.manual(800))])) == nil)
    }

    @Test func storedTextRoundTripsAndMatchesTheTwin() {
        let presets = [
            CameraSettingsPreset(id: "p1", name: "Day\texterior", values: [
                .exposureCompensation(Rational(-1, 3)), .iso(.manual(800)),
                .shutter(.duration(Rational(1, 50))), .aperture(2.8), .whiteBalance(.kelvin(5600)),
                .whiteBalanceTint(-3),
            ]),
            CameraSettingsPreset(id: "p2", name: "Night", values: [
                .iso(.autoLimited(maximum: 6400)), .shutter(.angle(172.8)), .whiteBalance(.preset("tungsten")),
            ]),
            CameraSettingsPreset(id: "p3", name: "Auto", values: [
                .iso(.auto), .shutter(.auto), .whiteBalance(.auto),
            ]),
        ]
        let text = CameraSettingsPresetCodec.encode(presets)
        #expect(text == """
            opencine-presets 1
            p1\tDay exterior\twb=5600K\ttint=-3.0\tiso=800\tshutter=1/50\taperture=2.8\tev=-1/3
            p2\tNight\twb=preset:tungsten\tiso=auto:6400\tshutter=172.8deg
            p3\tAuto\twb=auto\tiso=auto\tshutter=auto
            """)
        var expected = presets
        expected[0].name = "Day exterior"
        #expect(CameraSettingsPresetCodec.decode(text) == expected)
    }

    @Test func storedTextSkipsWhatItDoesNotUnderstand() {
        let text = """
            opencine-presets 1
            p1\tKept\tiso=400\tfocus=near\tshutter=1/0\tev=x
            p1\tDuplicate id\tiso=800
            \tNo id\tiso=800
            p2\tNothing known\tlut=rec709
            p3\tLater\twb=6500K
            """
        #expect(CameraSettingsPresetCodec.decode(text) == [
            CameraSettingsPreset(id: "p1", name: "Kept", values: [.iso(.manual(400))]),
            CameraSettingsPreset(id: "p3", name: "Later", values: [.whiteBalance(.kelvin(6500))]),
        ])
        #expect(CameraSettingsPresetCodec.decode("opencine-presets 2\np1\tNew\tiso=400").isEmpty)
        #expect(CameraSettingsPresetCodec.decode("").isEmpty)
    }

    @Test func aRejectionNamesASkipOnlyForWhatTheCameraCannotDo() {
        #expect(CameraSettingsPresetSkip(.unsupported) == .unsupported)
        #expect(CameraSettingsPresetSkip(.supportUnknown) == .unsupported)
        #expect(CameraSettingsPresetSkip(.readOnly) == .readOnly)
        #expect(CameraSettingsPresetSkip(.unavailable(.mode)) == .unavailable(.mode))
        #expect(CameraSettingsPresetSkip(.outOfDomain) == .outOfDomain)
        #expect(CameraSettingsPresetSkip(.noAuthority) == nil)
        #expect(CameraSettingsPresetSkip(.staleCapabilities) == nil)
        #expect(CameraSettingsPresetSkip(.cameraRefused) == nil)
    }
}
