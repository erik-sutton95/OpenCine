import Testing
@testable import OpenCineCameraVocabulary

@Suite struct CameraCaptureProfileTests {
    @Test func nativeIsoDeclarationsPreserveUnknownAndKnownUnsupported() {
        let legacy = CameraCaptureProfile(supportsFocusMode: true)
        #expect(legacy.nativeISO.hop == nil)
        #expect(legacy.nativeISO.ceiling == nil)
        let declared = CameraCaptureProfile(supportsFocusMode: true,
            nativeISO: .init(hop: false, ceiling: true))
        #expect(declared.supportsFocusMode == legacy.supportsFocusMode)
        #expect(declared.nativeISO.hop == false)
        #expect(declared.nativeISO.ceiling == true)
    }

    @Test func displayNamesCannotCreateCapabilities() {
        let named = CameraModel(name: "Osmo Pocket 3")
        #expect(named.captureProfile == nil)
        #expect(!named.supportsFocusMode && !named.supportsAperture && !named.supportsZoom)
        #expect(named.isoAutoRangeFloor == nil)
        #expect(ColorMode.normal.isoAutoBase(for: named) == nil)
        #expect(CamCapVideoFormat.pickerFormats(available: [], model: named,
            shootingMode: Int(ShootingMode.video.rawValue)).isEmpty)
    }

    @Test func aProfileWorksWithAnUnrelatedDisplayName() {
        let colors: [ColorMode] = [.normal, .iLog, .dolbyVision]
        let profile = CameraCaptureProfile(labels: CameraLabelProfile(colorModes: colors),
            supportsFocusMode: true, supportsAperture: true, supportsZoom: true,
            isoAutoRangeFloor: 50, zoom: CameraZoomProfile(stops: [1, 3, 6]))
        let model = CameraModel(name: "Unrelated display name", captureProfile: profile)
        #expect(model.supportsFocusMode && model.supportsAperture && model.supportsZoom)
        #expect(ColorMode.available(for: model) == colors)
        #expect(CamCapColorMode.wheel(available: colors, model: model) == colors)
        #expect(ColorMode.normal.isoAutoBase(for: model) == 50)
        #expect(model.activeZoomStops(resolution: nil, shootingMode: -1) == [1, 3, 6])
    }

    @Test func anUnknownProfilePreservesReportedColorChoices() {
        let colors: [ColorMode] = [.normal, .iLog, .dolbyVision]
        #expect(CamCapColorMode.wheel(available: colors, order: []) == colors)
        #expect(ColorMode.normal.isoAutoBase == nil)
    }

    /// The colour drum opens on the value the header shows: a reported current mode the body
    /// list lacks stays on the drum (shown, never offered for a SET); unknown adds nothing.
    @Test func theColorDrumKeepsTheReportedCurrentModeTheOfferedListLacks() {
        let offered: [ColorMode] = [.normal, .hdr]
        #expect(CamCapColorMode.drum(offered: offered, current: .dLog2) == [.normal, .hdr, .dLog2])
        #expect(CamCapColorMode.drum(offered: offered, current: .hdr) == offered)
        #expect(CamCapColorMode.drum(offered: offered, current: nil) == offered)
        #expect(CamCapColorMode.drum(offered: [], current: .iLog) == [.iLog])
    }
}
