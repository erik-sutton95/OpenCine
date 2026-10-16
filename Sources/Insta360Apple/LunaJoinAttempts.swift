import Foundation
import OpenCineCore

/// Counts system join requests iOS has not answered yet. iOS withholds the apply completion
/// while its "Join Wi-Fi Network" alert is up, so a pending request is an open prompt.
final class LunaJoinPrompt: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    var isPending: Bool { lock.lock(); defer { lock.unlock() }; return pending > 0 }
    func begin() { lock.lock(); pending += 1; lock.unlock() }
    func end() { lock.lock(); pending -= 1; lock.unlock() }
}

/// The retry loop around one camera Wi-Fi join. The camera AP needs a few seconds (sometimes
/// most of a minute) after the BLE handoff wakes it; iOS fails a join to an AP that is not up
/// yet (nehelper 37).
@MainActor
enum LunaJoinAttempts {
    struct Timing: Sendable {
        /// How long one attempt may take, not counting time the system Join prompt is up.
        var attempt: Duration = .seconds(35)
        var pause: Duration = .seconds(3)
        var tick: Duration = .milliseconds(250)
    }

    nonisolated static let timeoutFailure = ConnectionFailure.luna(
        .joinFailed, "wifi.join-timeout",
        "The camera Wi-Fi did not come up. Check that the camera is on and nearby, then try again.",
        phase: .joiningNetwork)

    /// - onCameraNetwork: true once the phone holds a camera address (auto-join, the operator
    ///   joined in Settings, or a late Join answer).
    /// - join: one attempt; it reports its system request through `prompt`.
    static func run(
        budget: Duration, timing: Timing = .init(),
        onCameraNetwork: @escaping @MainActor () -> Bool,
        validate: @escaping @MainActor () throws -> Void,
        attemptStarts: @escaping @MainActor (Int) -> Void = { _ in },
        log: @escaping @MainActor (String) -> Void,
        leave: @escaping @MainActor () -> Void,
        join: @escaping @MainActor (_ joinOnce: Bool, _ prompt: LunaJoinPrompt) async throws -> Void
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: budget)
        var attempt = 0
        while true {
            attempt += 1
            if onCameraNetwork() { return }
            attemptStarts(attempt)
            do {
                // Alternate persistent and join-once configs: iOS can refuse one kind
                // (internal error 8) while a user-saved network of the same name exists.
                let once = attempt % 2 == 0
                let prompt = LunaJoinPrompt()
                try await withTimeout(timing, prompt: prompt) { try await join(once, prompt) }
                return
            } catch {
                try validate()
                if onCameraNetwork() { return }
                log("luna: Wi-Fi join attempt \(attempt) failed: \(error.localizedDescription)")
                guard ContinuousClock.now < deadline else { throw error }
                // The AP may not beacon yet: drop the config so the next apply
                // associates fresh instead of reusing a stale one (upstream WiFiJoiner).
                leave()
                try await Task.sleep(for: timing.pause)
            }
        }
    }

    /// Fails the attempt after `timing.attempt` so the retry loop can try again. The clock stops
    /// while the system request is pending: giving up there and retrying put a second Join alert
    /// in front of an operator who answered the first one late (device cell 7c). The UI stays
    /// live meanwhile and Cancel still ends the connect.
    static func withTimeout(
        _ timing: Timing, prompt: LunaJoinPrompt, _ work: @escaping @MainActor () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work() }
            group.addTask {
                var remaining = timing.attempt
                while remaining > .zero {
                    let step = min(remaining, timing.tick)
                    try await Task.sleep(for: step)
                    if !prompt.isPending { remaining -= step }
                }
                throw timeoutFailure
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
