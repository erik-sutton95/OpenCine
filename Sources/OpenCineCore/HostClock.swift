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

/// `Task.sleep(for:)` as a named function: the default of a public injected wait parameter.
///
/// A closure literal in a public default argument is compiled again into each client module, and
/// at -Onone those copies disagree with the library's on the async context size. The linker can
/// pair one copy's body with another copy's size, so the closure writes past its task allocation
/// (swiftlang/swift#92017). A reference to this function has one definition and no copies.
public func hostSleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
}

/// `hostSleep(for:)` for a non-throwing wait: cancellation ends the wait early without an error.
public func hostSleepUntilCancelled(for duration: Duration) async {
    try? await Task.sleep(for: duration)
}
