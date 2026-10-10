import Foundation
import Testing

@testable import Insta360Apple

// SIMULATED: source reads at first native entry; actual TCP/BLE callsites use this same overload.
@MainActor @Suite struct LunaCommandFreshNativeSourceTests {
    @Test func nativeEpochReplacementDuringPredicateIsReadBeforeFirstSend() {
        let owner = LunaCommandOwner(), endpoint = NSObject()
        let source = LunaNativeCommandSource(transport: endpoint, epoch: 1, endpoint: endpoint)
        let successor = LunaNativeCommandSource(transport: endpoint, epoch: 2, endpoint: endpoint)
        let facts = LunaFirstSourceFacts(source)
        let admission = LunaCommandAdmission(owner: owner) {
            facts.replace(successor); return true
        }
        var first = LunaCommandFirstDispatch(admission: admission, source: source)
        var writes = 0, receipts = 0, reads = 0
        #expect(throws: LunaCommandAdmissionError.expired) {
            try first.perform(current: { reads += 1; return facts.read() },
                native: { writes += 1 }, didDispatch: { receipts += 1 })
        }
        #expect(reads == 1 && facts.predicateCalls == 1 && writes == 0 && receipts == 0 && !first.entered)
        #expect(facts.read() == successor)
        withExtendedLifetime(endpoint) {}
    }

    @Test func sourceReadReplacementCannotEnterCapturedNativeOperation() {
        let owner = LunaCommandOwner(), endpoint = NSObject()
        let source = LunaNativeCommandSource(transport: endpoint, epoch: 1, endpoint: endpoint)
        let facts = LunaFirstSourceFacts(source)
        let admission = LunaCommandAdmission(owner: owner) { facts.countPredicate(); return true }
        var first = LunaCommandFirstDispatch(admission: admission, source: source)
        var writes = 0, reads = 0
        #expect(throws: LunaCommandAdmissionError.expired) {
            try first.perform(current: { reads += 1; owner.replaceSource(); return source },
                native: { writes += 1 }, didDispatch: {})
        }
        #expect(reads == 1 && facts.predicateCalls == 1 && writes == 0 && !first.entered)
        #expect(LunaCommandAdmission(owner: owner, isCurrent: { true }).isCurrent)
        withExtendedLifetime(endpoint) {}
    }

    @Test func sourceReadRetirementCannotEnterCapturedNativeOperation() {
        let owner = LunaCommandOwner(), endpoint = NSObject()
        let source = LunaNativeCommandSource(transport: endpoint, epoch: 1, endpoint: endpoint)
        let facts = LunaFirstSourceFacts(source)
        let admission = LunaCommandAdmission(owner: owner) { facts.countPredicate(); return true }
        var first = LunaCommandFirstDispatch(admission: admission, source: source)
        var writes = 0, reads = 0
        #expect(throws: LunaCommandAdmissionError.expired) {
            try first.perform(current: { reads += 1; owner.retire(); return source },
                native: { writes += 1 }, didDispatch: {})
        }
        #expect(reads == 1 && facts.predicateCalls == 1 && writes == 0 && !first.entered)
        #expect(!admission.isCurrent && facts.predicateCalls == 1)
        withExtendedLifetime(endpoint) {}
    }

    @Test func enteredFrameNeverReadsOrRevokesItsLaterChunks() throws {
        let owner = LunaCommandOwner(), endpoint = NSObject()
        let source = LunaNativeCommandSource(transport: endpoint, epoch: 1, endpoint: endpoint)
        let facts = LunaFirstSourceFacts(source)
        let admission = LunaCommandAdmission(owner: owner) { facts.countPredicate(); return true }
        var first = LunaCommandFirstDispatch(admission: admission, source: source)
        var writes = 0, receipts = 0, reads = 0
        try first.perform(current: { reads += 1; return source }, native: { writes += 1 },
            didDispatch: { receipts += 1; owner.retire() })
        try first.perform(current: { reads += 1; return source }, native: { writes += 1 },
            didDispatch: { receipts += 1 })
        #expect(first.entered && writes == 2 && receipts == 1 && reads == 1 && facts.predicateCalls == 1)
        withExtendedLifetime(endpoint) {}
    }

    @Test func retiredOwnerSkipsPredicateAndNativeSourceRead() {
        let owner = LunaCommandOwner(), endpoint = NSObject()
        let source = LunaNativeCommandSource(transport: endpoint, epoch: 1, endpoint: endpoint)
        let facts = LunaFirstSourceFacts(source)
        let admission = LunaCommandAdmission(owner: owner) { facts.countPredicate(); return true }
        owner.retire()
        var first = LunaCommandFirstDispatch(admission: admission, source: source)
        var writes = 0, reads = 0
        #expect(throws: LunaCommandAdmissionError.expired) {
            try first.perform(current: { reads += 1; return source }, native: { writes += 1 }, didDispatch: {})
        }
        #expect(reads == 0 && facts.predicateCalls == 0 && writes == 0 && !first.entered)
        withExtendedLifetime(endpoint) {}
    }
}

private final class LunaFirstSourceFacts: @unchecked Sendable {
    private let lock = NSLock()
    private var source: LunaNativeCommandSource
    private var calls = 0
    init(_ source: LunaNativeCommandSource) { self.source = source }
    var predicateCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func countPredicate() { lock.lock(); calls += 1; lock.unlock() }
    func replace(_ next: LunaNativeCommandSource) { lock.lock(); calls += 1; source = next; lock.unlock() }
    func read() -> LunaNativeCommandSource { lock.lock(); defer { lock.unlock() }; return source }
}
