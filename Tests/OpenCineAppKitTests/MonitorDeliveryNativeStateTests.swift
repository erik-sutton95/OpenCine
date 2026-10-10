import Testing

@testable import OpenCineAppKit

@MainActor private final class NativeStateCleanupGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("SIMULATED existing native delivery state") @MainActor
struct MonitorDeliveryNativeStateTests {
    @Test func nativeStateCoversCapturedWaitUntilEnteredCleanupFinishes() async throws {
        let gate = NativeStateCleanupGate()
        let owner = MonitorDeliveryPresentation<String>(
            isCaching: { _ in false }, isExternalDelivery: { _ in false })
        defer {
            owner.close()
            gate.release()
        }
        let accepted = owner.beginNativeCaptured { _, _ in
            await gate.wait()
            return nil
        }
        let handle = try #require(accepted)
        for _ in 0..<1000 {
            if gate.continuation != nil { break }
            await Task.yield()
        }
        #expect(gate.continuation != nil)
        #expect(owner.nativeState.running)
        #expect(owner.nativeState.progress == nil)
        #expect(owner.display.overlay == nil)
        var joined = false
        let joining = Task {
            await handle.cancelAndJoin()
            joined = true
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!joined)
        #expect(!owner.nativeState.running)
        gate.release()
        await joining.value
        #expect(joined)
        #expect(!owner.nativeState.running)
        #expect(owner.display.overlay == nil)
        #expect(owner.display.toast == nil)
    }
}
