import Testing
@testable import OpenCineCameraVocabulary

@Suite struct CameraCaptureProfileTests {
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
}
