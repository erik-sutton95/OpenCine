import Testing

@testable import OpenCineApple

@Suite struct UVCCaptureSelectionTests {
    @Test func missingExplicitSelectionDoesNotOpenAnotherCamera() {
        #expect(
            UVCCaptureSelection.deviceID(
                available: ["desk", "capture"], preferred: nil,
                requiresExplicitSelection: true) == nil)
        #expect(
            UVCCaptureSelection.deviceID(
                available: ["desk"], preferred: "capture",
                requiresExplicitSelection: true) == nil)
        #expect(
            UVCCaptureSelection.deviceID(
                available: ["desk", "capture"], preferred: "capture",
                requiresExplicitSelection: true) == "capture")
    }

    @Test func existingAutomaticCaptureChoiceRemainsAvailable() {
        #expect(
            UVCCaptureSelection.deviceID(
                available: ["first", "second"], preferred: nil,
                requiresExplicitSelection: false) == "first")
        #expect(
            UVCCaptureSelection.deviceID(
                available: [], preferred: nil,
                requiresExplicitSelection: false) == nil)
    }

    @Test func requestedModeMustFitActualDimensionsAndRateRange() {
        let requested = UVCCaptureMode(width: 1920, height: 1080, framesPerSecond: 60)
        #expect(requested.matches(width: 1920, height: 1080, minimumRate: 30, maximumRate: 60))
        #expect(!requested.matches(width: 1920, height: 1080, minimumRate: 24, maximumRate: 30))
        #expect(!requested.matches(width: 3840, height: 2160, minimumRate: 30, maximumRate: 60))
        #expect(
            !UVCCaptureMode(width: 0, height: 1080, framesPerSecond: .nan)
                .matches(width: 0, height: 1080, minimumRate: 0, maximumRate: 60))
    }
}

@Suite("Which attached devices count as capture hardware")
struct CaptureHardwareFilterTests {
    @Test func aUSBDeviceNamingItsIDsIsCaptureHardware() {
        #expect(UVCCaptureSelection.isCaptureHardware(modelID: "UVC Camera VendorID_13407 ProductID_8496"))
    }

    @Test func theMacsOwnCameraAndVirtualCamerasAreNot() {
        for model in ["MacBookPro18,3", "OpenCine.Camera.1", "Virtual Camera Model", "iPhone17,2", ""] {
            #expect(!UVCCaptureSelection.isCaptureHardware(modelID: model), "\(model)")
        }
    }
}
