/// The one wait for hosted (in-process) tests whose state is produced by work the test does not
/// schedule itself: UIKit presentation, SwiftUI rendering, AVFoundation loading, a delivery run.
///
/// A fixed budget of `Task.yield()` rounds or a short wall-clock window measures how busy the
/// machine is, not whether the behavior happened, so the same correct code fails under parallel
/// load. This wait instead re-evaluates the actual state until it holds. Its limit only stops a
/// genuine hang; it is never the expected duration of anything.
public enum HostedCondition {
    /// The default hang guard: far beyond any healthy simulator latency, well inside the
    /// per-test execution allowance the gates set.
    public static let hangLimit: Duration = .seconds(30)

    /// Re-evaluates `condition` on the main actor until it holds, suspending between evaluations
    /// so the main run loop, UIKit, SwiftUI and every other task can make progress. Returns
    /// `true` once it holds, `false` only when `limit` passed first. The condition is evaluated
    /// once more after the limit, so a main thread stalled past it by machine load still observes
    /// state that became true meanwhile.
    @MainActor
    public static func wait(limit: Duration = hangLimit, until condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while true {
            if condition() { return true }
            if clock.now >= deadline { return condition() }
            // A short suspension, not a yield: it lets the run loop turn (presentations,
            // display link, main-queue callbacks), which a yield on the main actor does not.
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
