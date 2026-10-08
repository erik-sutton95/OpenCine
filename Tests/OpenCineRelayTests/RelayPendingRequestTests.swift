import Foundation
import OpenCineRelay
import Testing

/// SIMULATED request occurrences do not change the existing control lease revision.
@Suite struct RelayPendingRequestTests {
    @Test func rejectedRequestDoesNotAdvanceRequestOrLeaseRevision() {
        var control = RelayHostControl()
        let peer = UUID()
        control.register(peer, name: "SIMULATED watcher", authorized: false)
        let requestResult1 = !control.request(peer, allowsControl: true)
        #expect(requestResult1)
        control.register(peer, name: "SIMULATED watcher", authorized: true)
        let requestResult2 = !control.request(peer, allowsControl: false)
        #expect(requestResult2)
        #expect(control.requestRevision == 0 && control.revision == 0)
        #expect(control.pendingRequestRevision == nil && control.pendingRequest == nil)
    }
    @Test func declineAndSamePeerRequestHaveDistinctReceiptsWithoutChangingLeaseRevision() throws {
        var control = RelayHostControl()
        let peer = UUID()
        control.register(peer, name: "SIMULATED watcher", authorized: true)
        let requestResult3 = control.request(peer, allowsControl: true)
        #expect(requestResult3)
        let first = try #require(control.pendingRequest)
        let requestResult4 = control.declinePending(first)
        #expect(requestResult4)
        #expect(control.pendingRequestRevision == nil)
        let requestResult5 = control.request(peer, allowsControl: true)
        #expect(requestResult5)
        let next = try #require(control.pendingRequest)
        #expect(next.source == first.source && next.peer == first.peer)
        #expect(next.requestRevision == first.requestRevision + 1 && control.revision == 0)
        #expect(!control.admits(first) && control.admits(next))
    }
    @Test func staleGrantCannotConsumeRepeatedRequest() throws {
        var control = RelayHostControl()
        let peer = UUID()
        control.register(peer, name: "SIMULATED watcher", authorized: true)
        let requestResult6 = control.request(peer, allowsControl: true)
        #expect(requestResult6)
        let old = try #require(control.pendingRequest)
        control.declinePending()
        let requestResult7 = control.request(peer, allowsControl: true)
        #expect(requestResult7)
        let current = try #require(control.pendingRequest)
        let requestResult8 = !control.grantPending(old) && control.holder == nil && control.pendingRequest == current
        #expect(requestResult8)
        let requestResult9 = control.grantPending(current) && control.holder == peer
        #expect(requestResult9)
        #expect(control.pendingRequestRevision == nil && control.revision == 1)
    }
    @Test func staleDeclineCannotConsumeRepeatedRequest() throws {
        var control = RelayHostControl()
        let peer = UUID()
        control.register(peer, name: "SIMULATED watcher", authorized: true)
        let requestResult10 = control.request(peer, allowsControl: true)
        #expect(requestResult10)
        let old = try #require(control.pendingRequest)
        control.declinePending()
        let requestResult11 = control.request(peer, allowsControl: true)
        #expect(requestResult11)
        let current = try #require(control.pendingRequest)
        let requestResult12 = !control.declinePending(old) && control.pendingRequest == current
        #expect(requestResult12)
        let requestResult13 = control.declinePending(current) && control.pendingRequest == nil && control.revision == 0
        #expect(requestResult13)
    }
    @Test func sourceAndPeerReplacementCannotReplayOldRequest() throws {
        var control = RelayHostControl()
        let peer = UUID(), successor = UUID()
        control.register(peer, name: "same label", authorized: true)
        let requestResult14 = control.request(peer, allowsControl: true)
        #expect(requestResult14)
        let old = try #require(control.pendingRequest)
        control.register(successor, name: "same label", authorized: true)
        let requestResult15 = control.request(successor, allowsControl: true)
        #expect(requestResult15)
        let next = try #require(control.pendingRequest)
        let requestResult16 = !control.grantPending(old) && !control.declinePending(old)
        #expect(requestResult16)
        #expect(control.pendingRequest == next)
        control.resetSource()
        control.register(peer, name: "same label", authorized: true)
        let requestResult17 = control.request(peer, allowsControl: true)
        #expect(requestResult17)
        let requestResult18 = !control.grantPending(old) && !control.declinePending(old)
        #expect(requestResult18)
        #expect(control.pendingRequest?.source != old.source && control.pending == peer)
    }
    @Test func acceptedRequestsDoNotRevokeHeldCommandAdmission() throws {
        var control = RelayHostControl()
        let holder = UUID(), requester = UUID()
        control.register(holder, name: "SIMULATED holder", authorized: true)
        let requestResult19 = control.request(holder, allowsControl: true) && control.grantPending()
        #expect(requestResult19)
        let command = try #require(control.admission(for: holder)), revision = control.revision
        control.register(requester, name: "SIMULATED requester", authorized: true)
        let requestResult20 = control.request(requester, allowsControl: true)
        #expect(requestResult20)
        let request = try #require(control.pendingRequest)
        #expect(control.admits(command) && control.revision == revision)
        let requestResult21 = control.declinePending(request) && control.admits(command)
        #expect(requestResult21)
    }
}
