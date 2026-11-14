import OpenCineAppKit
import OpenCineCore
import Testing

/// The coordinator's deadline on a member link's repair. Kotlin twin: `MultiviewRepairRaceTest`.
@MainActor @Suite struct MultiviewRepairRaceTests {
    @Test func aRepairEndsWithItsOwnResultBeforeItsDeadline() async {
        let (never, hold) = AsyncStream.makeStream(of: Never.self)
        let result = await MultiviewRepairResult.race(
            deadline: .seconds(60),
            sleep: { _ in
                for await _ in never {}
                throw CancellationError()
            }
        ) { .waitForOperator("Taken over") }
        hold.finish()
        #expect(result == .waitForOperator("Taken over"))
    }

    @Test func aRepairStillRunningAtItsDeadlineIsCancelledAndEndsAsDone() async {
        let (hang, hold) = AsyncStream.makeStream(of: Never.self)
        let (ended, end) = AsyncStream.makeStream(of: Bool.self)
        let result = await MultiviewRepairResult.race(deadline: .seconds(60), sleep: { _ in }) {
            for await _ in hang {}
            end.yield(Task.isCancelled)
            return .rejoin
        }
        #expect(result == .done, "A repair past its deadline asks for nothing")
        var cancelled = ended.makeAsyncIterator()
        #expect(await cancelled.next() == true, "The repair was cancelled at its deadline")
        hold.finish()
    }
}
