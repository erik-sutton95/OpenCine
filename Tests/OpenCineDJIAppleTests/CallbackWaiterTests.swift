#if canImport(os)
import Foundation
import Testing

@testable import OpenCineDJIApple

@Suite struct DJIAppleCallbackWaiterTests {
    @Test func cancellationBeforeRegistrationIgnoresLateAndDuplicateSuccess() async {
        let abandoned = DjiAppleCallbackWaiter<Int>()
        abandoned.resolve(.failure(CancellationError()))
        abandoned.resolve(.success(7))
        abandoned.resolve(.success(8))
        do {
            let _: Int = try await withCheckedThrowingContinuation { abandoned.install($0) }
            Issue.record("A canceled callback must not manufacture success")
        } catch { #expect(error is CancellationError) }
    }

    @Test func anOldCallbackCannotResolveTheSuccessor() async throws {
        let old = DjiAppleCallbackWaiter<Int>()
        let successor = DjiAppleCallbackWaiter<Int>()
        old.resolve(.failure(CancellationError()))
        old.resolve(.success(999))
        let result = try await withCheckedThrowingContinuation { continuation in
            successor.install(continuation)
            old.resolve(.success(999))
            successor.resolve(.success(42))
            successor.resolve(.success(43))
        }
        #expect(result == 42)
    }

    private struct SimulatedDeadline: Error {}

    @Test func concurrentOSAndDeadlineCompletionsChooseExactlyOneResult() async {
        let waiter = DjiAppleCallbackWaiter<Int>()
        do {
            let result = try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                DispatchQueue.global().async { waiter.resolve(.failure(SimulatedDeadline())) }
                for value in 0..<32 {
                    DispatchQueue.global().async { waiter.resolve(.success(value)) }
                }
            }
            #expect((0..<32).contains(result))
        } catch {
            #expect(error is SimulatedDeadline)
        }
        // Even after the caller resumes, cancellation and late OS callbacks stay retired.
        waiter.resolve(.failure(CancellationError()))
        waiter.resolve(.success(100))
    }

    @Test func aSynchronousOSCompletionBeforeInstallIsRetained() async throws {
        let waiter = DjiAppleCallbackWaiter<Int>()
        waiter.resolve(.success(42))
        let result = try await withCheckedThrowingContinuation { waiter.install($0) }
        #expect(result == 42)
    }
}
#endif
