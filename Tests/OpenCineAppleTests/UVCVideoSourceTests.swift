#if os(iOS) && canImport(AVFoundation)
    import CoreMedia
    import Testing

    @testable import OpenCineApple

    @Suite struct UVCVideoSourceTests {
        @Test func broadcastShapeIsSixteenByNineOnly() {
            #expect(UVCVideoSource.isBroadcastShaped(CMVideoDimensions(width: 1920, height: 1080)))
            #expect(UVCVideoSource.isBroadcastShaped(CMVideoDimensions(width: 3840, height: 2160)))
            #expect(!UVCVideoSource.isBroadcastShaped(CMVideoDimensions(width: 4096, height: 2160)))
            #expect(!UVCVideoSource.isBroadcastShaped(CMVideoDimensions(width: 0, height: 1080)))
        }

        @Test func colorimetryNamesAreShortOrRaw() {
            #expect(UVCVideoSource.shortColorimetryName("ITU_R_709_2") == "709")
            #expect(UVCVideoSource.shortColorimetryName("SMPTE_ST_2084_PQ") == "PQ")
            #expect(UVCVideoSource.shortColorimetryName("Weird") == "Weird")
        }

        /// The capture device's USB identity comes from its model ID, then its unique ID, and the
        /// readout says which calibration the picture decodes with.
        @Test func deviceIdentityPicksTheCalibration() {
            let dongle = CaptureDeviceIdentity(vendorID: 0x345F, productID: 0x2130)
            #expect(
                UVCVideoSource.identity(
                    modelID: "UVC Camera VendorID_13407 ProductID_8496",
                    uniqueID: "0x1100000345f2130")
                    == dongle)
            #expect(
                UVCVideoSource.identity(
                    modelID: "UVC Camera", uniqueID: "UVC Camera VendorID_13407 ProductID_8496")
                    == dongle)
            let unnamed = UVCVideoSource.identity(
                modelID: "UVC Camera", uniqueID: "0x11213302e1a4c04")
            #expect(unnamed == nil)
            #expect(UVCVideoSource.calibrationReadout(dongle) == " · USB 345F:2130 calibrated")
            #expect(
                UVCVideoSource.calibrationReadout(CaptureDeviceIdentity(vendorID: 1, productID: 2))
                    == " · USB 0001:0002")
            #expect(UVCVideoSource.calibrationReadout(nil) == " · USB ID unread")
        }

        @Test func streamingStateIsTheOnlyLiveOne() {
            #expect(UVCVideoSourceState.streaming(deviceName: "Link", format: nil).isStreaming)
            #expect(!UVCVideoSourceState.waitingForDevice.isStreaming)
        }
    }
#endif
