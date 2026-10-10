import Foundation

/// Typed state sampling shares producer/cadence/stop ownership; apps supply readings only.
@MainActor public final class RelayStatePoller<State: Sendable> {
    private let scheduler: any RelayWatchScheduler
    private let interval: TimeInterval
    private var source: UUID?
    private var window = UUID()
    private var pending: (any RelayWatchScheduled)?
    private var read: (@MainActor () -> State?)?
    private var receive: (@MainActor (State) -> Void)?
    private var hasFailed: (@MainActor () -> Bool)?
    private var failure: (@MainActor () -> Void)?
    public init(interval: TimeInterval, scheduler: (any RelayWatchScheduler)? = nil) {
        precondition(interval.isFinite && interval > 0)
        self.interval = interval
        self.scheduler = scheduler ?? TaskClock()
    }
    public func begin(
        source: UUID, read: @escaping @MainActor () -> State?,
        receive: @escaping @MainActor (State) -> Void,
        hasFailed: @escaping @MainActor () -> Bool, onFailure: @escaping @MainActor () -> Void
    ) {
        stop()
        self.source = source
        self.read = read
        self.receive = receive
        self.hasFailed = hasFailed
        failure = onFailure
        tick(source, window: window)
    }
    public func stop() {
        source = nil
        window = UUID()
        pending?.cancel()
        pending = nil
        read = nil
        receive = nil
        hasFailed = nil
        failure = nil
    }
    private func tick(_ source: UUID, window: UUID) {
        guard self.source == source, self.window == window else { return }
        let failed = hasFailed?() == true
        guard self.source == source, self.window == window else { return }
        if failed {
            let failure = failure
            stop()
            failure?()
            return
        }
        let state = read?()
        guard self.source == source, self.window == window else { return }
        guard let state else {
            stop()
            return
        }
        receive?(state)
        guard self.source == source, self.window == window else { return }
        pending = scheduler.schedule(after: interval) { [weak self] in
            self?.tick(source, window: window)
        }
    }
    @MainActor private final class TaskClock: RelayWatchScheduler {
        func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void)
            -> any RelayWatchScheduled
        {
            Ticket(seconds: seconds, action: action)
        }
    }
    @MainActor private final class Ticket: RelayWatchScheduled {
        private var task: Task<Void, Never>?
        init(seconds: TimeInterval, action: @escaping @MainActor () -> Void) {
            task = Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled { action() }
            }
        }
        func cancel() {
            task?.cancel()
            task = nil
        }
    }
}
