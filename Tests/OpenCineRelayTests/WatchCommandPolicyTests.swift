import OpenCineRelay
import Testing

/// SIMULATED camera facts and dispatch outcomes; no transport or hardware operations.
@Suite struct WatchCommandPolicyTests {
    @Test func exactPreflightMatrixNeverDispatchesARefusedAction() {
        for recording in [false, true] {
            for action in [RelayWatchAction.capture, .toggleRecord, .resume] {
                for (busy, live, photo, error) in [
                    (true, false, false, WatchRelayCopy.busy),
                    (true, false, true, WatchRelayCopy.busy),
                    (true, true, false, WatchRelayCopy.busy),
                    (true, true, true, WatchRelayCopy.busy),
                    (false, false, false, WatchRelayCopy.connectFirst),
                    (false, false, true, WatchRelayCopy.connectFirst),
                ] {
                    var dispatched = false
                    let answer = WatchCommandPolicy.answer(
                        action,
                        facts: {
                            .init(
                                isRecording: recording, isBusy: busy, isLive: live,
                                isPhotography: photo)
                        },
                        shutter: {
                            dispatched = true
                            return .sent
                        })
                    #expect(!dispatched && !answer.accepted)
                    #expect(answer.error == error)
                    #expect(answer.isRecording == (busy ? recording : false))
                }
            }
            for (action, photo, error) in [
                (RelayWatchAction.capture, false, WatchRelayCopy.switchToPhoto),
                (.toggleRecord, true, WatchRelayCopy.switchToVideo),
                (.resume, false, "unavailable"),
                (.resume, true, "unavailable"),
            ] {
                var dispatched = false
                let answer = WatchCommandPolicy.answer(
                    action,
                    facts: {
                        .init(
                            isRecording: recording, isBusy: false, isLive: true,
                            isPhotography: photo)
                    },
                    shutter: {
                        dispatched = true
                        return .sent
                    })
                #expect(!dispatched && !answer.accepted && answer.error == error)
                #expect(answer.isRecording == (action == .resume ? false : recording))
            }
        }
    }

    @Test func dispatchOutcomeIsIndependentOfTheRecordingLampAndUsesPostDispatchReport() {
        for (action, photo) in [(RelayWatchAction.capture, true), (.toggleRecord, false)] {
            for (dispatch, accepted, error) in [
                (WatchCommandDispatch.sent, true, nil as String?),
                (.notSent, false, WatchRelayCopy.busy),
                (.targetChanged, false, WatchRelayCopy.cameraChanged),
            ] {
                for changesRecording in [false, true] {
                    var recording = false
                    var submissions = 0
                    let answer = WatchCommandPolicy.answer(
                        action,
                        facts: {
                            .init(
                                isRecording: recording, isBusy: false, isLive: true,
                                isPhotography: photo)
                        },
                        shutter: {
                            submissions += 1
                            recording = changesRecording
                            return dispatch
                        })
                    #expect(
                        submissions == 1 && answer.accepted == accepted && answer.error == error)
                    #expect(answer.isRecording == changesRecording)
                }
            }
        }
    }
}
