import OpenCineCore
import Testing

@Suite struct MonitorConnectionPolicyTests {
    @Test func connectionOwnershipKeepsCommandsSeparateFromReadings() {
        for owns in [false, true] {
            for metadata in [false, true] {
                for token in [false, true] {
                    let policy = MonitorConnectionPolicy(ownsCameraSession: owns,
                        receivesCameraMetadata: metadata, holdsRelayControl: token)
                    #expect(policy.canDriveCamera == (owns || token))
                    #expect(policy.cameraControls == (owns || token))
                    #expect(policy.recordControl == (owns || token))
                    #expect(policy.mediaBrowser == owns)
                    #expect(policy.offersSourceSwitch == owns)
                    #expect(policy.focusBoxes == metadata)
                    #expect(policy.focusConfirmation == metadata)
                    #expect(policy.subjectDetectionBoxes == metadata)
                    #expect(policy.audioMeters == metadata)
                    #expect(policy.cameraTimecode == metadata)
                    #expect(policy.cameraLevel == metadata)
                }
            }
        }
        #expect(MonitorConnectionPolicy.owning.cameraControls)
        #expect(!MonitorConnectionPolicy.watcher(holdsControl: false).cameraControls)
        #expect(MonitorConnectionPolicy.watcher(holdsControl: true).cameraControls)
        #expect(!MonitorConnectionPolicy.watcher(holdsControl: true).mediaBrowser)
    }
}
