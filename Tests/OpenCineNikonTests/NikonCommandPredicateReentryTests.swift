import Foundation
import OpenCineNikon
import Testing

// SIMULATED: retirement at the captured native-entry boundary, without a camera or transport.
@Suite struct NikonCommandPredicateReentryTests {
    @Test func predicateRetirementCannotEnterCapturedNativeOperation() {
        let owner = NikonCommandOwner(), calls = NikonPredicateCalls()
        let admission = NikonCommandAdmission(owner: owner) {
            calls.increment(); owner.retire(); return true
        }
        var writes = 0
        #expect(rejectsExpiredCommand {
            try admission.perform { writes += 1 }
        })
        #expect(writes == 0 && calls.value == 1)
        #expect(!admission.isCurrent && calls.value == 1)
    }

    @Test func falseReentrantPredicateCannotEnterCapturedNativeOperation() {
        let owner = NikonCommandOwner(), calls = NikonPredicateCalls()
        let admission = NikonCommandAdmission(owner: owner) {
            calls.increment(); owner.retire(); return false
        }
        var writes = 0
        #expect(rejectsExpiredCommand {
            try admission.perform { writes += 1 }
        })
        #expect(writes == 0 && calls.value == 1)
        #expect(NikonCommandAdmission(owner: NikonCommandOwner(), isCurrent: { true }).isCurrent)
    }

    @Test func currentPredicateRunsOnceAtNativeEntry() throws {
        let owner = NikonCommandOwner(), calls = NikonPredicateCalls()
        let admission = NikonCommandAdmission(owner: owner) { calls.increment(); return true }
        var writes = 0
        #expect(try admission.perform { writes += 1; return "entered" } == "entered")
        #expect(writes == 1 && calls.value == 1)
    }

    @Test func enteredOperationKeepsItsOriginalCompletion() throws {
        let owner = NikonCommandOwner(), calls = NikonPredicateCalls()
        let admission = NikonCommandAdmission(owner: owner) { calls.increment(); return true }
        var writes = 0
        let result = try admission.perform { writes += 1; owner.retire(); return "original completion" }
        #expect(result == "original completion" && writes == 1 && calls.value == 1)
        #expect(!admission.isCurrent && calls.value == 1)
    }
}

private func rejectsExpiredCommand(_ operation: () throws -> Void) -> Bool {
    do { try operation(); return false }
    catch {
        if case NativeCameraSessionError.commandAuthorityExpired = error { return true }
        return false
    }
}

private final class NikonPredicateCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
