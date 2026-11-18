import Testing

@testable import OpenCineDJI

/// The feed watchdog waits after a camera SET because a SET can pause the encoder. A read cannot.
/// Field report OpenPocketCine#639: the 2 Hz tracking poll counted as a SET, so with tracking on
/// every stall waited about 6 s for its first repair instead of 2 s.
@Suite struct LiveCameraReadTests {
    @Test func readsAreRecognized() {
        let reads: [(String, Duml.Frame)] = [
            ("tracking poll", Commands.pollTracking()),
            ("parameter GET", Commands.paramGet(.isoLimit)),
            ("audio DSP GET", Commands.audioDspGet()),
            ("focus track GET", Commands.getFocusTrack()),
        ]
        for (name, frame) in reads {
            #expect(Duml.isLiveCameraRead(frame), "\(name) only reads camera state")
        }
    }

    @Test func writesAreNotReads() {
        let writes: [(String, Duml.Frame)] = [
            ("parameter SET on the GET opcode", Commands.paramSet(.isoLimit, value: [0x01])),
            ("tracking box clear", Commands.clearTrackingBox()),
            ("exposure compensation", Commands.setEv(.zero)),
        ]
        for (name, frame) in writes {
            #expect(!Duml.isLiveCameraRead(frame), "\(name) changes the camera")
        }
    }

    @Test func anEmptyParameterFrameIsNotARead() {
        let frame = Duml.Frame(
            sender: 0x02, receiver: 0x01, seq: 0, flags: 0x40,
            cmdSet: 0x02, cmdId: 0x8E, payload: [])
        #expect(!Duml.isLiveCameraRead(frame))
    }

    @Test func theSameCommandOnAnotherSetIsNotACameraRead() {
        let frame = Duml.Frame(
            sender: 0x02, receiver: 0x01, seq: 0, flags: 0x40,
            cmdSet: 0x04, cmdId: 0xA5, payload: [0x00])
        #expect(!Duml.isLiveCameraRead(frame))
    }
}
