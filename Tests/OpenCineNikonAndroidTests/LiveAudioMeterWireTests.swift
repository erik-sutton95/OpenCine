import OpenCineNikon
import Testing

@testable import OpenCineNikonAndroid

struct LiveAudioMeterWireTests {
    @Test func absentCameraIndicatorStaysExplicitlyUnavailable() {
        let wire = LiveAudioMeterWire(sound: nil)

        #expect(!wire.hasLevels)
        #expect(wire.leftLevelDB == -60)
        #expect(wire.leftPeakDB == -60)
        #expect(wire.rightLevelDB == -60)
        #expect(wire.rightPeakDB == -60)
    }

    @Test func cameraIndicatorUsesTheSharedCoreDBFSMapping() {
        let sound = PTPLiveViewSoundIndicator(
            peakLeft: 14,
            peakRight: 10,
            currentLeft: 8,
            currentRight: 3)
        let wire = LiveAudioMeterWire(sound: sound)

        // Segment 0 is the -60 dBFS floor, segment 14 is 0 dBFS, evenly spaced in dB.
        #expect(wire.hasLevels)
        #expect(wire.leftLevelDB == -60 * (1 - 8.0 / 14))
        #expect(wire.leftPeakDB == 0)
        #expect(wire.rightLevelDB == -60 * (1 - 3.0 / 14))
        #expect(wire.rightPeakDB == -60 * (1 - 10.0 / 14))
    }
}
