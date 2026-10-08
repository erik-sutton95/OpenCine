import Foundation
import OpenCineRelay
import Testing

@Suite @MainActor struct RelayStatePollerTests {
    @Test func retiredScheduledTickCannotReadOrDispatchOnSameSourceReentry() {
        let clock = Clock()
        let poller = RelayStatePoller<Int>(interval: 0.2, scheduler: clock)
        let source = UUID()
        var reads = 0
        var values: [Int] = []
        poller.begin(
            source: source,
            read: {
                reads += 1
                return 1
            }, receive: { values.append($0) }, hasFailed: { false }, onFailure: {})
        #expect(reads == 1 && values == [1] && clock.timers[0].seconds == 0.2)
        poller.stop()
        #expect(clock.timers[0].canceled)
        poller.begin(
            source: source,
            read: {
                reads += 1
                return 2
            }, receive: { values.append($0) }, hasFailed: { false }, onFailure: {})
        clock.fire(0)
        #expect(reads == 2 && values == [1, 2] && clock.timers.count == 2)
        clock.fire(1)
        #expect(reads == 3 && values == [1, 2, 2] && clock.timers.count == 3)
        poller.stop()
        clock.fire(2)
        #expect(reads == 3 && values == [1, 2, 2])
    }

    @Test func nilOrFailureRetiresPollerOnceWithoutDispatchOrCommandOnClose() {
        let clock = Clock()
        let poller = RelayStatePoller<Int>(interval: 0.2, scheduler: clock)
        var state: Int? = 3
        var values: [Int] = []
        let failure = FailureState()
        var failures = 0
        poller.begin(
            source: UUID(), read: { state }, receive: { values.append($0) }, hasFailed: { failure.failed },
            onFailure: { failures += 1 })
        state = nil
        clock.fire(0)
        #expect(values == [3] && failures == 0 && clock.timers.count == 1)
        state = 4
        poller.begin(
            source: UUID(), read: { state }, receive: { values.append($0) }, hasFailed: { failure.failed },
            onFailure: { failures += 1 })
        failure.failed = true
        clock.fire(1)
        clock.fire(1)
        #expect(values == [3, 4] && failures == 1 && clock.timers.count == 2)
        poller.stop()
        #expect(failures == 1)
    }

    @Test func reentrantReadAndFailurePortCannotStopOrScheduleSuccessorWindow() {
        let clock = Clock()
        let poller = RelayStatePoller<Int>(interval: 0.2, scheduler: clock)
        let source = UUID()
        var values: [Int] = []
        var failures = 0
        let beginSuccessor = {
            poller.begin(
                source: source, read: { 9 }, receive: { values.append($0) }, hasFailed: { false },
                onFailure: { failures += 1 })
        }
        poller.begin(
            source: source,
            read: {
                beginSuccessor()
                return nil
            }, receive: { values.append($0) }, hasFailed: { false }, onFailure: { failures += 1 })
        #expect(values == [9] && failures == 0 && clock.timers.count == 1)
        clock.fire(0)
        #expect(values == [9, 9] && clock.timers.count == 2)
        poller.begin(
            source: source, read: { 1 }, receive: { values.append($0) },
            hasFailed: {
                beginSuccessor()
                return true
            }, onFailure: { failures += 1 })
        #expect(values == [9, 9, 9] && failures == 0 && clock.timers.count == 3)
        clock.fire(1)
        #expect(values == [9, 9, 9] && clock.timers.count == 3)
        clock.fire(2)
        #expect(values == [9, 9, 9, 9] && failures == 0)
        poller.stop()
    }

    @MainActor private final class FailureState { var failed = false }

    @MainActor private final class Clock: RelayWatchScheduler {
        @MainActor final class Timer: RelayWatchScheduled {
            let seconds: TimeInterval
            let action: @MainActor () -> Void
            var canceled = false
            init(seconds: TimeInterval, action: @escaping @MainActor () -> Void) {
                self.seconds = seconds
                self.action = action
            }
            func cancel() { canceled = true }
        }
        var timers: [Timer] = []
        func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void)
            -> any RelayWatchScheduled
        {
            let timer = Timer(seconds: seconds, action: action)
            timers.append(timer)
            return timer
        }
        /// Deliberately fires canceled work to exercise a noncooperative scheduler.
        func fire(_ index: Int) { timers[index].action() }
    }
}
