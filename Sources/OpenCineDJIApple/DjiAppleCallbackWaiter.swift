#if canImport(os)
import Foundation
import os

/// An OS completion, cancellation and a deadline compete for one continuation.
/// Every access to the result/continuation pair is protected by the same lock;
/// completion runs after unlocking so a resumed caller may reenter safely.
final class DjiAppleCallbackWaiter<Value: Sendable>: Sendable {
    private struct State: Sendable {
        var result: Result<Value, Error>?
        var continuation: CheckedContinuation<Value, Error>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let resolved = state.withLock { state -> Result<Value, Error>? in
            if let result = state.result { return result }
            precondition(state.continuation == nil, "A callback wait owns one continuation")
            state.continuation = continuation
            return nil
        }
        if let resolved { continuation.resume(with: resolved) }
    }

    func resolve(_ result: Result<Value, Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Value, Error>? in
            guard state.result == nil else { return nil }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
#endif
