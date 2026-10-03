import Foundation
import OpenCineDJI
import OpenCineDJIApple
import Testing

@Suite @MainActor
struct DJIAppleControlExchangeTests {
    /// SIMULATED packets cross the same public endpoint and timing seam as native composition.
    @MainActor private final class Peer {
        var time: TimeInterval = 0
        var wakes: [(TimeInterval, @MainActor @Sendable () -> Void)] = []
        var writes: [(TimeInterval, Duml.Frame)] = []
        var bleWrites: [Duml.Frame] = []
        var sequence: UInt16 = 0
        var policy = DjiAppleControlContext(canTransmit: true)
        var effects: [DjiAppleControlExchange.Event] = []
        lazy var exchange = DjiAppleControlExchange(
            endpoint: .init(writeBLE: { [unowned self] in bleWrites.append($0) }, writeDatalink: { [unowned self] frame in
                writes.append((time, frame)); defer { sequence &+= 1 }; return .queued(sequence)
            }), timing: .init(now: { [unowned self] in time }, schedule: { [unowned self] delay, wake in
                let components = delay.components
                wakes.append((time + Double(components.seconds) + Double(components.attoseconds) / 1e18, wake))
            }), context: { [unowned self] in policy }, event: { [unowned self] in effects.append($0) })
        func advance(to deadline: TimeInterval) {
            while let next = wakes.enumerated().filter({ $0.element.0 <= deadline + 1e-12 })
                .min(by: { $0.element.0 < $1.element.0 }) {
                time = next.element.0; wakes.remove(at: next.offset); next.element.1()
            }
            time = deadline
        }
    }
    private func frame(_ cmd: UInt8 = 1, seq: UInt16 = 0, payload: [UInt8] = [0]) -> Duml.Frame {
        .init(sender: 1, receiver: 2, seq: seq, flags: Duml.flagResponse,
            cmdSet: 2, cmdId: cmd, payload: payload)
    }
    @Test func simulatedRegistrationPrecedesSynchronousReplyAndGroupedCompletionIsOnce() async throws {
        let peer = Peer(), reply = frame()
        let request = peer.exchange.request(matching: [(2, 1), (2, 2)]) {
            peer.exchange.receive(reply)
            peer.exchange.receive(frame(2))
        }
        #expect(try await request.value() == reply)
        peer.advance(to: 8)
        #expect(try await request.value() == reply)
    }
    @Test func simulatedOldCancelCannotCancelSameGenerationSuccessor() async throws {
        let peer = Peer()
        let old = peer.exchange.request(matching: [(2, 1)])
        let successor = peer.exchange.request(matching: [(2, 1)])
        old.cancel()
        peer.exchange.receive(frame())
        #expect(try await successor.value() == frame())
    }
    @Test func simulatedRetirementAndOldDeadlineCannotCancelSuccessor() async throws {
        let peer = Peer()
        let old = peer.exchange.request(matching: [(2, 1)], timeout: .seconds(1))
        peer.exchange.retire(CancellationError())
        let next = peer.exchange.request(matching: [(2, 1)], timeout: .seconds(3))
        old.cancel(); peer.advance(to: 1)
        peer.exchange.receive(frame())
        #expect(try await next.value() == frame())
    }
    @Test func simulatedPinnedSettlementCannotConfirmDifferentActualReport() {
        let peer = Peer()
        peer.policy.legacySettlement.isoIndex = .iso800
        var report = CameraStatus(); report.isoIndex = .iso100
        peer.policy.reported = report
        var stages: [ControlWireEvent] = [], settlements: [Bool] = []
        peer.exchange.submit(.init(frame(), name: "ISO", expectation: .iso(.iso800))) {
            if case .stage(let stage) = $0 { stages.append(stage) }
            if case .settled(let result) = $0 { settlements.append(result) }
        }
        peer.advance(to: 2)
        #expect(stages == [.sent, .unconfirmed])
        #expect(settlements == [true], "Compatibility busy release keeps its original meaning")
        #expect(!peer.effects.contains { if case .timeoutEvidence = $0 { true } else { false } })
    }
    @Test func simulatedUnobservedRecordingIsNotReportedIdle() {
        let peer = Peer(); peer.policy.reported = CameraStatus()
        var stages: [ControlWireEvent] = []
        peer.exchange.submit(.init(frame(), name: "Stop", expectation: .recording(false))) {
            if case .stage(let stage) = $0 { stages.append(stage) }
        }
        peer.advance(to: 2)
        #expect(stages == [.sent, .unconfirmed])
    }
    @Test func simulatedRetryAndSettleKeepOriginalDeadlinesAndLateZeroSequence() {
        let peer = Peer()
        var stages: [ControlWireEvent] = [], settlements: [Bool] = []
        peer.exchange.submit(.init(frame(), name: "ISO")) {
            if case .stage(let stage) = $0 { stages.append(stage) }
            if case .settled(let result) = $0 { settlements.append(result) }
        }
        peer.advance(to: 0.299); #expect(peer.writes.count == 1)
        peer.advance(to: 0.3); #expect(peer.writes.count == 2)
        peer.advance(to: 1.999); #expect(settlements.isEmpty)
        peer.advance(to: 2); #expect(settlements == [true]); #expect(stages == [.sent, .unconfirmed])
        peer.exchange.receive(frame(seq: 0))
        #expect(stages.last == .acknowledged)
    }
    @Test func simulatedPhotoNeverRetransmitsAndRetirementSendsNoCommand() {
        let peer = Peer()
        peer.exchange.submit(.init(frame(), name: "Photo", retransmits: false))
        peer.advance(to: 0.3); #expect(peer.writes.count == 1)
        peer.exchange.retire(CancellationError(), notifySets: true)
        peer.advance(to: 5); #expect(peer.writes.count == 1)
    }
    @Test func simulatedOrdinaryCoalesceWaits100msAndSupersededPendingNeverSends() {
        let peer = Peer()
        peer.exchange.submit(.init(frame(payload: [1]), name: "A", coalesce: true))
        var stages: [ControlWireEvent] = []
        peer.exchange.submit(.init(frame(payload: [2]), name: "B", coalesce: true)) {
            if case .stage(let stage) = $0 { stages.append(stage) }
        }
        peer.exchange.submit(.init(frame(payload: [3]), name: "C", coalesce: true))
        peer.advance(to: 0.02); peer.exchange.receive(frame(seq: 0))
        peer.advance(to: 0.099); #expect(peer.writes.count == 1)
        peer.advance(to: 0.1)
        #expect(peer.writes.map { $0.1.payload } == [[1], [3]])
        #expect(stages == [.notSent])
    }
    @Test func simulatedZoomPipelines50msAndOldWakeCannotSendYoungerSuccessorEarly() {
        let peer = Peer()
        peer.exchange.submit(.init(frame(0xb8, payload: [1]), name: "A", coalesce: true))
        peer.exchange.submit(.init(frame(0xb8, payload: [2]), name: "B", coalesce: true))
        peer.advance(to: 0.049); #expect(peer.writes.count == 1)
        peer.advance(to: 0.05); #expect(peer.writes.count == 2)
        peer.exchange.submit(.init(frame(0xb8, payload: [3]), name: "C", coalesce: true))
        peer.advance(to: 0.1); #expect(peer.writes.count == 3)
        peer.exchange.cancelSet(CameraSetMailbox.zoomOpcodeKey)
        peer.exchange.submit(.init(frame(0xb8, payload: [4]), name: "D", coalesce: true))
        peer.exchange.submit(.init(frame(0xb8, payload: [5]), name: "E", coalesce: true))
        peer.advance(to: 0.149); #expect(peer.writes.count == 4)
        peer.advance(to: 0.15); #expect(peer.writes.count == 5)
        peer.advance(to: 0.3)
        #expect(peer.writes.map { $0.1.payload }.prefix(5) == [[1], [2], [3], [4], [5]])
    }
    @Test func simulatedNackPinnedMatchKeepsLegacyBusyReleaseWithoutCommonConfirmation() {
        let peer = Peer(); peer.policy.legacySettlement.isoIndex = .iso800
        var report = CameraStatus(); report.isoIndex = .iso100; peer.policy.reported = report
        var stages: [ControlWireEvent] = [], settlements: [Bool] = []
        peer.exchange.submit(.init(frame(), name: "ISO", expectation: .iso(.iso800))) {
            if case .stage(let stage) = $0 { stages.append(stage) }
            if case .settled(let settled) = $0 { settlements.append(settled) }
        }
        peer.exchange.receive(frame(payload: [0xd9]))
        #expect(stages == [.sent, .refused]); #expect(settlements == [true])
        #expect(peer.effects.contains { if case .legacySettlementMatched = $0 { true } else { false } })
    }
    @Test func simulatedActualRecordingReportCanConfirmIdleWithoutAcknowledgement() {
        let peer = Peer()
        var report = CameraStatus(); report.recordingReported = true; peer.policy.reported = report
        var stages: [ControlWireEvent] = []
        peer.exchange.submit(.init(frame(), name: "Stop", expectation: .recording(false))) {
            if case .stage(let stage) = $0 { stages.append(stage) }
        }
        peer.advance(to: 2)
        #expect(stages == [.sent, .confirmed])
    }
    @Test func simulatedSetSequenceWinsGetWaiterAndUnsolicitedFlipConsumesNeither() async throws {
        let peer = Peer()
        var stages: [ControlWireEvent] = []
        peer.exchange.submit(.init(frame(0x8e), name: "Audio")) {
            if case .stage(let stage) = $0 { stages.append(stage) }
        }
        let get = peer.exchange.request(matching: [(2, 0x8e)])
        peer.exchange.receive(frame(0x8e, payload: [0, 0, 1, 0x38, 0, 1, 1]))
        #expect(stages == [.sent])
        #expect(peer.effects.contains { if case .selfieFlip = $0 { true } else { false } })
        peer.exchange.receive(frame(0x8e))
        #expect(stages == [.sent, .acknowledged])
        let reply = frame(0x8e, seq: 40, payload: [0, 0, 1, 0x20, 0, 1, 1])
        peer.exchange.receive(reply)
        #expect(try await get.value() == reply)
    }
    @Test func simulatedPairingHoldPreservesApprovalAndWifiFreshRegistration() async throws {
        let peer = Peer()
        let approval = Duml.Frame(sender: 2, receiver: 1, seq: 19, flags: Duml.flagRequest,
            cmdSet: 7, cmdId: 0x46, payload: [0])
        peer.exchange.receive(approval)
        #expect(peer.bleWrites == [Commands.pairApprovalAck(seq: 19)])
        let held = peer.exchange.request(matching: [(7, 0x45), (7, 0x46)]) {
            Issue.record("A held approval does not send pairing again")
        }
        #expect(try await held.value() == approval)
        var stale = approval; stale.cmdId = 7; stale.flags = Duml.flagResponse
        peer.exchange.receive(stale)
        var fresh = stale; fresh.seq = 20; fresh.payload = [0, 1]
        let wifi = peer.exchange.request(matching: [(7, 7)], consumeHold: false) {
            peer.exchange.receive(fresh)
        }
        #expect(try await wifi.value() == fresh)
    }
    @Test func simulatedControlsOnlyDoesNotAcknowledgePairingOrForwardFlip() {
        let peer = Peer(); peer.policy.controlsOnly = true
        peer.exchange.receive(.init(sender: 2, receiver: 1, seq: 19, flags: Duml.flagRequest,
            cmdSet: 7, cmdId: 0x46, payload: [0]))
        peer.exchange.receive(frame(0x8e, payload: [0, 0, 1, 0x38, 0, 1, 1]))
        #expect(peer.bleWrites.isEmpty); #expect(peer.effects.isEmpty)
    }
    @Test func simulatedWrappedSequenceAndOldReceiptCannotRetireSuccessor() {
        let peer = Peer(); peer.sequence = .max
        var a: [ControlWireEvent] = [], b: [ControlWireEvent] = []
        peer.exchange.submit(.init(frame(0xb8), name: "A", coalesce: true)) {
            if case .stage(let stage) = $0 { a.append(stage) }
        }
        peer.advance(to: 0.05)
        peer.exchange.submit(.init(frame(0xb8), name: "B", coalesce: true)) {
            if case .stage(let stage) = $0 { b.append(stage) }
        }
        peer.exchange.receive(frame(0xb8, seq: .max))
        #expect(a == [.sent]); #expect(b == [.sent])
        peer.exchange.receive(frame(0xb8, seq: 0))
        #expect(b == [.sent, .acknowledged])
    }
    @Test func simulatedOldScheduledWakeCannotConsumeYoungerPendingOrUnrelatedKey() {
        let peer = Peer()
        peer.exchange.submit(.init(frame(0xb8, payload: [1]), name: "Old zoom", coalesce: true))
        peer.exchange.submit(.init(frame(0xb8, payload: [2]), name: "Old pending", coalesce: true))
        peer.exchange.submit(.init(frame(1, payload: [7]), name: "ISO", coalesce: true))
        peer.exchange.submit(.init(frame(1, payload: [8]), name: "ISO pending", coalesce: true))
        peer.advance(to: 0.04)
        peer.exchange.cancelSet(CameraSetMailbox.zoomOpcodeKey)
        peer.exchange.submit(.init(frame(0xb8, payload: [3]), name: "New zoom", coalesce: true))
        peer.exchange.submit(.init(frame(0xb8, payload: [4]), name: "New pending", coalesce: true))
        peer.exchange.receive(frame(1, seq: 1))
        peer.advance(to: 0.05); #expect(peer.writes.map { $0.1.payload } == [[1], [7], [3]])
        peer.advance(to: 0.089); #expect(peer.writes.count == 3)
        // Native scheduling retains the original millisecond round-up.
        peer.advance(to: 0.091); #expect(peer.writes.map { $0.1.payload } == [[1], [7], [3], [4]])
        peer.advance(to: 0.101); #expect(peer.writes.map { $0.1.payload } == [[1], [7], [3], [4], [8]])
    }
    @Test func simulatedAdmissionAndMediaGuardsPreserveFailureContract() {
        let peer = Peer(); peer.policy.canTransmit = false
        var stages: [ControlWireEvent] = []; var failures = 0; var settled: [Bool] = []
        let event: (DjiAppleControlExchange.SetEvent) -> Void = {
            switch $0 {
            case .stage(let stage): stages.append(stage)
            case .failed: failures += 1
            case .settled(let result): settled.append(result)
            }
        }
        peer.exchange.submit(.init(frame(), name: "ISO"), event: event)
        peer.policy.canTransmit = true; peer.policy.browsingMedia = true
        peer.exchange.submit(.init(frame(0x8e), name: "Audio"), event: event)
        #expect(peer.writes.isEmpty); #expect(stages == [.notSent, .notSent])
        #expect(failures == 1); #expect(settled == [false, false])
    }
    @Test func simulatedRetirementNotifiesSetOnceAndBorrowedEndpointStaysOpen() {
        let peer = Peer(); var failures = 0; var settled: [Bool] = []
        peer.exchange.submit(.init(frame(2), name: "Record")) {
            if case .failed = $0 { failures += 1 }
            if case .settled(let result) = $0 { settled.append(result) }
        }
        peer.exchange.retire(CancellationError(), notifySets: true)
        peer.exchange.retire(CancellationError(), notifySets: true)
        peer.advance(to: 5)
        #expect(failures == 1); #expect(settled == [false])
        #expect(peer.writes.count == 1)
        #expect(peer.exchange.endpoint.writeDatalink(frame(1)) == .queued(1),
            "Returning borrowed control never closes its transport")
    }
    @Test func simulatedOneBleDrainRejectsRetiredStreamAndOnlyCurrentEndDisconnects() async throws {
        let peer = Peer()
        let old = AsyncStream<Duml.Frame>.makeStream(), current = AsyncStream<Duml.Frame>.makeStream()
        peer.exchange.startBLEDrain(old.stream)
        peer.exchange.startBLEDrain(current.stream)
        let request = peer.exchange.request(matching: [(2, 1)])
        old.continuation.yield(frame(seq: 9)); old.continuation.finish()
        current.continuation.yield(frame(seq: 10))
        #expect(try await request.value().seq == 10)
        let next = peer.exchange.request(matching: [(2, 2)])
        current.continuation.finish()
        do { _ = try await next.value(); Issue.record("Ended BLE must retire its waiting GET") }
        catch { #expect(error is DjiAppleControlExchange.Error) }
        #expect(peer.effects.filter { if case .bleEnded = $0 { true } else { false } }.count == 1)
        #expect(peer.effects.filter { if case .bleActivity = $0 { true } else { false } }.count == 1)
        peer.exchange.stopBLEDrain()
    }

    @Test func simulatedSkippedWriteCannotCreditSequenceZeroAcknowledgement() {
        let peer = Peer(); var stages: [ControlWireEvent] = []
        peer.exchange.endpoint.writeDatalink = { _ in .skipped }
        peer.exchange.submit(.init(frame(), name: "Skipped", retransmits: false)) {
            if case .stage(let stage) = $0 { stages.append(stage) }
        }
        peer.exchange.receive(frame(seq: 0))
        #expect(stages == [.sent])
        peer.advance(to: 2)
        #expect(stages == [.sent, .unconfirmed])
        #expect(!peer.effects.contains { if case .replyReceived = $0 { true } else { false } })
    }

}
