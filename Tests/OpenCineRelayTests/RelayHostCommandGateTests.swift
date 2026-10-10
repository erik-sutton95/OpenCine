import Foundation
import OpenCineRelay
import Testing

@Suite struct RelayHostCommandGateTests {
    private func receipt() throws -> RelayHostControl.Admission {
        var control = RelayHostControl()
        let peer = UUID()
        control.register(peer, name: "SIMULATED", authorized: true)
        _ = control.request(peer, allowsControl: true)
        _ = control.grantPending()
        return try #require(control.admission(for: peer))
    }

    @Test func currentPublicationAdmitsExactlyItsSourcePeerRevisionAndSavedIdentity() throws {
        let gate = RelayHostCommandGate()
        let admission = try receipt()
        #expect(
            gate.publish(
                gate.publication, source: admission.source,
                revision: admission.revision, admission: admission, watcherID: "saved"))
        #expect(gate.admits(admission))
        #expect(gate.admits(source: admission.source, revision: admission.revision))
        #expect(gate.admits(watcherID: "saved"))
        #expect(!gate.admits(watcherID: "") && !gate.admits(watcherID: "another"))
        #expect(!gate.admits(source: UUID(), revision: admission.revision))
    }

    @Test func immediateRetirementBlocksAQueuedOldPublicationBeforeItsTransportRuns() throws {
        let gate = RelayHostCommandGate()
        let queued = gate.publication
        let admission = try receipt()
        _ = gate.publish(
            queued, source: admission.source, revision: admission.revision,
            admission: admission, watcherID: "saved")
        let successor = gate.retire()
        #expect(gate.isCurrent(successor) && !gate.isCurrent(queued))
        #expect(!gate.admits(admission) && !gate.admits(watcherID: "saved"))
        #expect(
            !gate.publish(
                queued, source: admission.source, revision: admission.revision,
                admission: admission, watcherID: "saved"))
        #expect(!gate.admits(admission))
    }

    @Test func successorPublicationSurvivesAnOldQueueFinallyAndSecondRetirement() throws {
        let gate = RelayHostCommandGate()
        let old = gate.publication
        let first = gate.retire()
        let newest = gate.retire()
        let admission = try receipt()
        #expect(
            !gate.publish(
                first, source: admission.source, revision: admission.revision,
                admission: admission, watcherID: "saved"))
        #expect(
            gate.publish(
                newest, source: admission.source, revision: admission.revision,
                admission: admission, watcherID: "saved"))
        #expect(!gate.publish(old, source: UUID(), revision: 0, admission: nil, watcherID: nil))
        #expect(gate.admits(admission))
    }

    @Test func wrongOwnerCannotBorrowARepeatedSourceOrPublicationGeneration() throws {
        let first = RelayHostCommandGate()
        let second = RelayHostCommandGate()
        let admission = try receipt()
        #expect(
            !second.publish(
                first.publication, source: admission.source,
                revision: admission.revision, admission: admission, watcherID: "saved"))
        #expect(!second.admits(admission))
    }

    @Test func alreadyEnteredNativeWorkCompletesWhileTheNextUnsentReadFailsOffActor() async throws {
        let gate = RelayHostCommandGate()
        let admission = try receipt()
        _ = gate.publish(
            gate.publication, source: admission.source, revision: admission.revision,
            admission: admission, watcherID: "saved")
        let entered = gate.admits(admission)
        gate.retire()
        let next = await Task.detached { gate.admits(admission) }.value
        #expect(entered && !next)
    }

    @MainActor @Test func actualHostRetiredQueueCannotPublishOrRetireItsSuccessor() throws {
        let owner = RelayHostSession(
            codec: SharedMonitorRelayCodec(),
            policy: .init(versionMismatchReason: "version", passcodeReason: "passcode"),
            startsActive: true, now: { Date(timeIntervalSince1970: 0) },
            execute: { $0() }, schedule: { _, _ in })
        let peer = RelayHostSessionPeer()
        owner.install(peer)
        try owner.handle(
            .init(
                kind: 1,
                payload: JSONEncoder().encode(
                    RelayPeerHello(
                        version: 1, hostName: "SIMULATED", passcode: "", watcherID: "saved")),
                consumedBytes: 0), from: peer)
        try owner.handle(.init(kind: 0x10, payload: Data(), consumedBytes: 0), from: peer)
        owner.grantControl()
        let first = try #require(owner.admission(watcherID: "saved"))
        let old = owner.commandGate.publication
        let successor = owner.commandGate.retire()
        var dispatched = 0
        owner.onCommand = { _, _ in dispatched += 1 }
        // An older queued grant still uses the retired publication, even if it changes control.
        owner.grantControl()
        try owner.handle(
            .init(
                kind: 0x12,
                payload: JSONEncoder().encode(WatcherRelayCommand.toggleRecording), consumedBytes: 0
            ),
            from: peer)
        #expect(dispatched == 0 && !owner.commandGate.admits(first))
        owner.reclaimControl(publication: successor)
        try owner.handle(.init(kind: 0x10, payload: Data(), consumedBytes: 0), from: peer)
        owner.grantControl()
        let current = try #require(owner.admission(watcherID: "saved"))
        #expect(owner.commandGate.admits(current))
        let source = owner.source
        owner.retireSource(publication: old)
        #expect(owner.source == source && owner.commandGate.admits(current))
        try owner.handle(
            .init(
                kind: 0x12,
                payload: JSONEncoder().encode(WatcherRelayCommand.toggleRecording), consumedBytes: 0
            ),
            from: peer)
        #expect(dispatched == 1)
        owner.stop()
    }
}
