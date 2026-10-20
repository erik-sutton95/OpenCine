import Foundation

/// A UI step's time budget that counts only the app's time. Test-side work inside the step, such
/// as a `checkpoint` (an accessibility snapshot, hit tests and a screenshot: seconds on a hosted
/// runner), moves the deadline later by exactly what it took. Without that, a slow runner spends
/// a presentation's budget on the test's own reads: on the 2026-10-20 nightly a 4.4 s checkpoint
/// left the share's Close 0.6 s of its 5 s, and the ready wait needs two settled reads.
struct TransitionBudget {
    private(set) var deadline: Date
    private let now: () -> Date

    init(seconds: TimeInterval, now: @escaping () -> Date = Date.init) {
        self.now = now
        deadline = now().addingTimeInterval(seconds)
    }

    /// Runs `work` without spending the budget: the deadline moves by `work`'s duration.
    mutating func excluding<T>(_ work: () throws -> T) rethrows -> T {
        let start = now()
        defer { deadline += now().timeIntervalSince(start) }
        return try work()
    }
}

/// The gallery's drag selection as the shared UI tests perform it.
enum GallerySweep {
    /// How long the sweep holds the first clip before dragging. The native hold
    /// (`MonitorMediaSelectionConfiguration.holdMilliseconds`) must fire first; if the drag's
    /// first move reaches the app before it, the long press fails and nothing is selected.
    static let pressSeconds: TimeInterval = 1.0
    /// A loaded hosted simulator stalls the app's main thread for tenths of a second, which
    /// delays the hold's timer but not the queued move behind it.
    static let minimumHoldMargin: TimeInterval = 0.5
}
