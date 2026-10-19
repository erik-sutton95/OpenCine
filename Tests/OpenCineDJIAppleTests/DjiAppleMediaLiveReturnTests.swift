import Foundation
import OpenCineDJI
import OpenCineDJIApple
import Testing

/// SIMULATED operation facts on a manual clock; the native host supplies genuine picture facts.
@MainActor @Suite struct DjiAppleMediaLiveReturnTests {
    @Test func acceptedEnableWaitsTheKeyframeIntervalAndExhaustsTheDeadline() async {
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
        // The 2 s budget starts at the request (0.18 s), inside one keyframe resend interval.
        #expect(result == .exhausted && exits == 1 && enables == 1)
        #expect(now >= 2.18 && now < 2.3)
    }

    /// C5b (2026-10-19): after a 51 min gallery the first IRAP hit a dead VT session; the one
    /// enable was never repeated and the session was dropped although video kept arriving.
    @Test func unusableFirstAnswerIsRequestedAgainAtKeyframeCadence() async {
        var now: TimeInterval = 0
        let timing = DjiAppleMediaTiming(
            now: { now },
            sleep: { delay in
                let value = delay.components
                now += Double(value.seconds) + Double(value.attoseconds) / 1e18
            })
        var enableTimes: [TimeInterval] = []
        var usableAnswerAt: TimeInterval?
        let result = await DjiAppleMediaLiveReturn.run(
            timing: timing,
            isCurrent: { true }, inPlayback: { false },
            pictureFresh: { usableAnswerAt.map { now >= $0 + 0.3 } ?? false },
            exitPlayback: { true },
            enableLiveView: {
                enableTimes.append(now)
                if enableTimes.count == 2 { usableAnswerAt = now }
                return true
            })
        #expect(result == .restored && enableTimes.count == 2)
        #expect(enableTimes.count == 2
            && enableTimes[1] - enableTimes[0] >= FeedWatchdog.keyframeResendInterval)
    }

    @Test func refusedResendAfterAKeptEnableRetriesWithoutAnotherKeyframeDelay() async {
        var now: TimeInterval = 0
        let timing = DjiAppleMediaTiming(
            now: { now },
            sleep: { delay in
                let value = delay.components
                now += Double(value.seconds) + Double(value.attoseconds) / 1e18
            })
        var attempts: [TimeInterval] = []
        var first = true
        let result = await DjiAppleMediaLiveReturn.run(
            timeout: .seconds(16), timing: timing,
            isCurrent: { true }, inPlayback: { false }, pictureFresh: { now >= 3.5 },
            exitPlayback: {
                now += 0.45
                return true
            },
            enableLiveView: {
                attempts.append(now)
                if first {
                    first = false
                    return true
                }
                return false
            })
        #expect(result == .restored)
        // Accepted at 0.63 s, refused at 2.63 s, then asked again at the loop pace.
        #expect(attempts.count == 10)
        #expect(attempts.count > 2 && abs(attempts[2] - 2.73) < 0.01)
        #expect(attempts.count > 2 && attempts[2] < attempts[1] + FeedWatchdog.keyframeResendInterval)
    }

    @Test func pictureBudgetStartsAtTheFirstLiveViewRequestNotAtPlaybackExit() async {
        var now: TimeInterval = 0
        let timing = DjiAppleMediaTiming(
            now: { now },
            sleep: { delay in
                let value = delay.components
                now += Double(value.seconds) + Double(value.attoseconds) / 1e18
            })
        var exits = 0
        var firstEnableAt: TimeInterval?
        let result = await DjiAppleMediaLiveReturn.run(
            timeout: .seconds(16), timing: timing,
            isCurrent: { true }, inPlayback: { exits < 7 }, pictureFresh: { false },
            exitPlayback: {
                exits += 1
                now += 2
                return true
            },
            enableLiveView: {
                if firstEnableAt == nil { firstEnableAt = now }
                return true
            })
        #expect(result == .exhausted && exits == 7)
        let first = firstEnableAt ?? .infinity
        #expect(now >= first + 16 && now < first + 16.2)
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
