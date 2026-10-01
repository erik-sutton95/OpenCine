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

        @Test func streamingStateIsTheOnlyLiveOne() {
            #expect(UVCVideoSourceState.streaming(deviceName: "Link", format: nil).isStreaming)
            #expect(!UVCVideoSourceState.waitingForDevice.isStreaming)
        }
    }
#endif
