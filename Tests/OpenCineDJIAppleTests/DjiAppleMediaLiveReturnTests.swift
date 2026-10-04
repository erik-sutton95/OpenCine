import Foundation
import OpenCineDJIApple
import Testing

/// SIMULATED operation facts on a manual clock; the native host supplies genuine picture facts.
@MainActor @Suite struct DjiAppleMediaLiveReturnTests {
    @Test func oneAcceptedEnableWaitsForPictureAndExhaustsTheDeadline() async {
        var now: TimeInterval = 0
        let timing = DjiAppleMediaTiming(
            now: { now },
            sleep: { delay in
                let value = delay.components
                now += Double(value.seconds) + Double(value.attoseconds) / 1e18
            })
        var exits = 0
        var enables = 0
        let result = await DjiAppleMediaLiveReturn.run(
            timeout: .seconds(2), timing: timing,
            isCurrent: { true }, inPlayback: { false }, pictureFresh: { false },
            exitPlayback: {
                exits += 1
                return true
            },
            enableLiveView: {
                enables += 1
                return true
            })
        #expect(result == .exhausted && exits == 1 && enables == 1)
        #expect(now >= 2 && now < 2.2)
    }

    @Test func lateExitCompletionCannotEnableAfterRetirement() async {
        var current = true
        var enables = 0
        let timing = DjiAppleMediaTiming(now: { 0 }, sleep: { _ in })
        let result = await DjiAppleMediaLiveReturn.run(
            timing: timing,
            isCurrent: { current }, inPlayback: { false }, pictureFresh: { false },
            exitPlayback: {
                current = false
                return true
            },
            enableLiveView: {
                enables += 1
                return true
            })
        #expect(result == .superseded && enables == 0)
    }

    @Test func currentReturnRequiresActualAcceptedEnableAndPicture() async {
        var now: TimeInterval = 0
        var enables = 0
        let timing = DjiAppleMediaTiming(
            now: { now },
            sleep: { delay in
                let value = delay.components
                now += Double(value.seconds) + Double(value.attoseconds) / 1e18
            })
        let result = await DjiAppleMediaLiveReturn.run(
            timing: timing,
            isCurrent: { true }, inPlayback: { false }, pictureFresh: { enables == 1 },
            exitPlayback: { true },
            enableLiveView: {
                enables += 1
                return true
            })
        #expect(result == .restored && enables == 1)
    }
}
