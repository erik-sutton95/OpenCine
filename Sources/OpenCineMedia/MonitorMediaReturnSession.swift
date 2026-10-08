import Foundation

/// One pending return claim, separate from the integration's actual recovery/exit policy.
/// Explicit entry, replacement and cancellation retire before outgoing work is canceled.
@MainActor public final class MonitorMediaReturnSession {
    public private(set) var generation = 0
    public private(set) var task: Task<Void, Never>?
    public var pending: Bool { task != nil }

    public init() {}

    public func cancel() {
        generation &+= 1
        let previous = task
        task = nil
        previous?.cancel()
    }

    /// A captured SDK predicate permits this request; the supplied operation claims the real
    /// recovery slot. This owner never infers a recording, connection or live-view command.
    @discardableResult public func start(
        ifCurrent: @escaping @MainActor (Int) -> Bool,
        operation: @escaping @MainActor (Int) async -> Void,
        completed: @escaping @MainActor (Int) -> Void = { _ in }
    ) -> Int {
        cancel()
        let token = generation
        guard ifCurrent(token), generation == token else { return token }
        let next = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.task = nil } }
            guard self.generation == token, !Task.isCancelled, ifCurrent(token),
                self.generation == token else { return }
            await operation(token)
            guard self.generation == token else { return }
            self.task = nil
            guard !Task.isCancelled, ifCurrent(token), self.generation == token else { return }
            completed(token)
        }
        if generation == token { task = next } else { next.cancel() }
        return token
    }
}
