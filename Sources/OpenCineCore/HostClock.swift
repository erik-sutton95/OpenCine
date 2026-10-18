import Foundation

/// Injectable host time for a timed product step: the monotonic instant its deadlines are measured
/// on, the wall date its stamps carry, and the sleep between its polls.
///
/// Production uses `.live`, the real clocks (`MonotonicInstant.now()`, `Date()`, `Task.sleep`), so
/// a type that takes a `HostClock` with that default behaves exactly as before. Tests pass
/// `ManualHostClock.clock` (OpenCineCoreTestSupport) and move time with `advance(by:)`, so a
/// confirmation window, an editor pin or a rate limit is crossed without waiting in real time.
/// This is the one clock seam the apps and integrations share; do not add a per-type copy.
public struct HostClock: Sendable {
    /// Now on the host's monotonic reference (deadlines, windows, rate limits).
    public var now: @Sendable () -> MonotonicInstant
    /// Now on the wall clock, for code whose stamps are `Date`s.
    public var date: @Sendable () -> Date
    /// Suspends for `duration` on this clock. Throws `CancellationError` when the task is cancelled.
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(
        now: @escaping @Sendable () -> MonotonicInstant,
        date: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.now = now
        self.date = date
        self.sleep = sleep
    }

    /// The real clocks.
    public static let live = HostClock(
        now: { MonotonicInstant.now() }, date: { Date() },
        sleep: { try await Task.sleep(for: $0) })
}
