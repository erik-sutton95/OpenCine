import Foundation
import Testing

@testable import Insta360Apple

// SIMULATED: controlled receipt retirement and entered frame chunks, without native IO.
@MainActor @Suite struct LunaCommandPredicateReentryTests {
    @Test func predicateReplacementCannotEnterCapturedNativeOperation() {
        let owner = LunaCommandOwner(), calls = LunaPredicateCalls()
        let admission = LunaCommandAdmission(owner: owner) {
            calls.increment(); owner.replaceSource(); return true
        }
        var writes = 0
        #expect(throws: LunaCommandAdmissionError.expired) {
            try admission.requireCurrent(); writes += 1
        }
        #expect(writes == 0 && calls.value == 1)
        let successor = LunaCommandAdmission(owner: owner, isCurrent: { true })
        #expect(successor.source != admission.source && successor.isCurrent)
        #expect(!admission.isCurrent && calls.value == 1)
    }

    @Test func predicateRetirementCannotEnterCapturedNativeOperation() {
        let owner = LunaCommandOwner(), calls = LunaPredicateCalls()
        let admission = LunaCommandAdmission(owner: owner) {
            calls.increment(); owner.retire(); return true
        }
        var writes = 0
        #expect(throws: LunaCommandAdmissionError.expired) {
            try admission.requireCurrent(); writes += 1
        }
        #expect(writes == 0 && calls.value == 1)
        owner.replaceSource()
        #expect(!LunaCommandAdmission(owner: owner, isCurrent: { true }).isCurrent)
    }

    @Test func falseReentrantPredicateLeavesSuccessorAdmitted() {
        let owner = LunaCommandOwner(), calls = LunaPredicateCalls()
        let admission = LunaCommandAdmission(owner: owner) {
            calls.increment(); owner.replaceSource(); return false
        }
        var writes = 0
        #expect(throws: LunaCommandAdmissionError.expired) {
            try admission.requireCurrent(); writes += 1
        }
        #expect(writes == 0 && calls.value == 1)
        #expect(LunaCommandAdmission(owner: owner, isCurrent: { true }).isCurrent)
    }

    @Test func enteredOperationKeepsItsOriginalCompletion() throws {
        let owner = LunaCommandOwner(), calls = LunaPredicateCalls()
        let admission = LunaCommandAdmission(owner: owner) { calls.increment(); return true }
        let endpoint = NSObject()
        let source = LunaNativeCommandSource(transport: endpoint, epoch: 1, endpoint: endpoint)
        var first = LunaCommandFirstDispatch(admission: admission, source: source)
        var writes = 0, entered = 0
        try first.perform(current: source, native: { writes += 1 }, didDispatch: { entered += 1 })
        owner.retire(); owner.replaceSource()
        let successor = LunaNativeCommandSource(transport: endpoint, epoch: 2, endpoint: endpoint)
        try first.perform(current: successor, native: { writes += 1 }, didDispatch: { entered += 1 })
        #expect(writes == 2 && entered == 1 && first.entered && calls.value == 1)
        #expect(!admission.isCurrent && calls.value == 1)
        withExtendedLifetime(endpoint) {}
    }
}

private final class LunaPredicateCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
