import OpenCineCore

/// The coordinator's deadline on a member link's repair. Kotlin twin: `MultiviewRepairResult.race`
/// in `:appkit`.
extension MultiviewRepairResult {
    /// Runs `work` against `deadline` (the link's `repairDeadline`): its own result when it ends
    /// first; `done` when the deadline passes first, after cancelling it. A repair that ignores
    /// cancellation keeps running, but its late result is dropped: the coordinator stops treating
    /// the member as recovering at the deadline. Cancelling the caller cancels `work`.
    @MainActor
    public static func race(
        deadline: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        _ work: @escaping @MainActor () async -> MultiviewRepairResult
    ) async -> MultiviewRepairResult {
        let (results, report) = AsyncStream.makeStream(of: MultiviewRepairResult.self)
        let worker = Task { @MainActor in report.yield(await work()) }
        let timer = Task {
            do { try await sleep(deadline) } catch { return }
            report.yield(.done)
        }
        defer {
            timer.cancel()
            worker.cancel()
        }
        return await withTaskCancellationHandler {
            var first = results.makeAsyncIterator()
            return await first.next() ?? .done
        } onCancel: {
            worker.cancel()
        }
    }
}
