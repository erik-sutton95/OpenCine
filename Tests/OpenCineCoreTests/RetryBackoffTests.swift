import OpenCineCore
import Testing

@Suite("Retry backoff")
struct RetryBackoffTests {
    @Test(arguments: [
        (0, 0.5, 0.5), (1, 0.5, 1.0), (2, 0.5, 2.0), (3, 0.5, 4.0),
        (20, 0.5, 30.0), (3, 0.0, 2.8), (3, 1.0, 5.2),
        (20, 0.0, 21.0), (20, 1.0, 30.0), (-3, 0.5, 0.5),
        (0, -1.0, 0.35), (0, 2.0, 0.65),
    ])
    func validVectorsRemainGolden(attempt: Int, jitter: Double, expected: Double) {
        let backoff = RetryBackoff(initialDelay: 0.5, maximumDelay: 30)
        #expect(abs(backoff.delay(forAttempt: attempt, jitter: jitter) - expected) < 1e-9)
    }

    @Test func callerScaleAndGrowthArePreserved() {
        let milliseconds = RetryBackoff(initialDelay: 500, maximumDelay: 8000)
        #expect(milliseconds.delay(forAttempt: 1, jitter: 0.5) == 1000)
        #expect(milliseconds.delay(forAttempt: 20, jitter: 1) == 8000)
        let otherGrowth = RetryBackoff(initialDelay: 2, maximumDelay: 10, multiplier: 1.5)
        #expect(otherGrowth.delay(forAttempt: 3, jitter: 0.5) == 6.75)
    }

    @Test func fractionalDelayIsNotRoundedByThePolicy() {
        let backoff = RetryBackoff(initialDelay: 3, maximumDelay: 10, multiplier: 1)
        #expect(abs(backoff.delay(forAttempt: 0, jitter: 1) - 3.9) < 1e-9)
    }
}
