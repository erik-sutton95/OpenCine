import Testing

@testable import OpenCineCameraVocabulary

@Suite struct CaptureLadderTests {
    @Test func recordingAndCameraControlFreezeTheSheet() {
        #expect(CaptureLock.recording.freezesSheet)
        #expect(CaptureLock.cameraControl.freezesSheet)
        #expect(!CaptureLock.auto.freezesSheet)
        #expect(!CaptureLock.exposureProgram.freezesSheet)
    }

    @Test func anUnknownCurrentAndAnOpenLockStayNull() {
        let ladder = CaptureLadder(current: nil, values: ["Wide"])
        #expect(ladder.current == nil)
        #expect(ladder.lock == nil)
        #expect(ladder.marked.isEmpty)
    }

    @Test func aTintMayOmitTheAmberBlueAxis() {
        let tint = CaptureTint(greenMagenta: 2, amberBlue: nil, range: -6...6)
        #expect(tint.amberBlue == nil)
        #expect(tint.greenMagenta == 2)
    }
}
