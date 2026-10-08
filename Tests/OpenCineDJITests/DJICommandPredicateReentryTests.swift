import Foundation
import OpenCineDJI
import Testing

// SIMULATED: controlled admission callbacks and native entry, without a camera or socket.
@Suite struct DJICommandPredicateReentryTests {
    @Test func predicateReplacementCannotEnterCapturedNativeOperation() throws {
        let owner = DJICommandOwner(), calls = DJIPredicateCalls()
        let admission = DJICommandAdmission(owner: owner) {
            calls.increment(); owner.replaceSource(); return true
        }
        var writes = 0
        #expect(throws: DJICommandAdmissionError.expired) {
            try admission.perform { writes += 1 }
        }
        #expect(writes == 0 && calls.value == 1)
        let successor = DJICommandAdmission(owner: owner, isCurrent: { true })
        #expect(successor.source != admission.source)
        #expect(try successor.perform { "successor" } == "successor")
        #expect(!admission.isCurrent && calls.value == 1)
    }

    @Test func predicateRetirementCannotEnterCapturedNativeOperation() {
        let owner = DJICommandOwner(), calls = DJIPredicateCalls()
        let admission = DJICommandAdmission(owner: owner) {
            calls.increment(); owner.retire(); return true
        }
        var writes = 0
        #expect(throws: DJICommandAdmissionError.expired) {
            try admission.perform { writes += 1 }
        }
        #expect(writes == 0 && calls.value == 1)
        owner.replaceSource()
        #expect(!DJICommandAdmission(owner: owner, isCurrent: { true }).isCurrent)
    }

    @Test func falseReentrantPredicateLeavesSuccessorAdmitted() throws {
        let owner = DJICommandOwner(), calls = DJIPredicateCalls()
        let admission = DJICommandAdmission(owner: owner) {
            calls.increment(); owner.replaceSource(); return false
        }
        var writes = 0
        #expect(throws: DJICommandAdmissionError.expired) {
            try admission.perform { writes += 1 }
        }
        #expect(writes == 0 && calls.value == 1)
        let successor = DJICommandAdmission(owner: owner, isCurrent: { true })
        #expect(try successor.perform { writes += 1; return "current" } == "current")
        #expect(writes == 1 && successor.isCurrent)
    }

    @Test func currentPredicateRunsOnceAtNativeEntry() throws {
        let owner = DJICommandOwner(), calls = DJIPredicateCalls()
        let admission = DJICommandAdmission(owner: owner) { calls.increment(); return true }
        var writes = 0
        #expect(try admission.perform { writes += 1; return "entered" } == "entered")
        #expect(writes == 1 && calls.value == 1)
    }

    @Test func enteredOperationKeepsItsOriginalCompletion() throws {
        let owner = DJICommandOwner(), calls = DJIPredicateCalls()
        let admission = DJICommandAdmission(owner: owner) { calls.increment(); return true }
        var writes = 0
        let result = try admission.perform {
            writes += 1; owner.retire(); owner.replaceSource(); return "original completion"
        }
        #expect(result == "original completion" && writes == 1 && calls.value == 1)
        #expect(!admission.isCurrent && calls.value == 1)
    }
}

private final class DJIPredicateCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
