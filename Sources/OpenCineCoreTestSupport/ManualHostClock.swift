import Foundation
import OpenCineCore

/// A `HostClock` that moves only when the test says so. `clock` hands it to the code under test;
/// `advance(by:)` moves time forward and resumes every sleep that ends on or before the new time,
/// in deadline order. A sleep that its caller starts again after waking waits for the next
/// `advance`, so a polling loop takes exactly one turn per advance that reaches its next deadline.
/// Use `pendingSleeps` (with a hosted wait) to know a loop has parked before advancing.
public final class ManualHostClock: @unchecked Sendable {
    private struct Sleeper {
        let id: UInt64
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var elapsedTime: Duration = .zero
    private var sleepers: [Sleeper] = []
    private var cancelled: Set<UInt64> = []
    private var nextID: UInt64 = 0
    private let origin: MonotonicInstant
    private let dateOrigin: Date

    /// - Parameters:
    ///   - origin: the monotonic instant the clock starts at.
    ///   - date: the wall date the clock starts at.
    public init(
        origin: MonotonicInstant = .zero, date: Date = Date(timeIntervalSinceReferenceDate: 0)
    ) {
        self.origin = origin
        self.dateOrigin = date
    }

    /// The clock to inject into the code under test.
    public var clock: HostClock {
        HostClock(
            now: { [self] in now }, date: { [self] in date },
            sleep: { [self] duration in try await sleep(for: duration) })
    }

    /// Time moved so far.
    public var elapsed: Duration { lock.withLock { elapsedTime } }
    public var now: MonotonicInstant { origin + elapsed }
    public var date: Date {
        let elapsed = elapsed.components
        return dateOrigin.addingTimeInterval(
            Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
    /// Sleeps currently parked on this clock.
    public var pendingSleeps: Int { lock.withLock { sleepers.count } }

    /// Moves time forward by `duration` and resumes every sleep whose end it reaches.
    public func advance(by duration: Duration) {
        precondition(duration >= .zero, "A manual clock only moves forward")
        let due: [Sleeper] = lock.withLock {
            elapsedTime += duration
            let target = elapsedTime
            let due = sleepers.filter { $0.deadline <= target }
                .sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
            sleepers.removeAll { $0.deadline <= target }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    private func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let id: UInt64 = lock.withLock {
            nextID &+= 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Start { case park, resume, cancel }
                let start: Start = lock.withLock {
                    if cancelled.remove(id) != nil { return .cancel }
                    let deadline = elapsedTime + duration
                    if deadline <= elapsedTime { return .resume }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .park
                }
                switch start {
                case .park: break
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let parked: Sleeper? = lock.withLock {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
                    // Not parked yet (or already resumed): a later park sees the mark and throws.
                    cancelled.insert(id)
                    return nil
                }
                return sleepers.remove(at: index)
            }
            parked?.continuation.resume(throwing: CancellationError())
        }
    }
}
