import Foundation
import OpenCineDJI
import OpenCineDJIApple
import Testing

@MainActor
@Suite("DJI native admission at the actual SET queue")
struct DJIAppleControlExchangeAdmissionTests {
    @Test(arguments: [true, false])
    func enteredPredecessorACKSurvivesRefusalBeforeOrAfterItArrives(beforeRefusal: Bool) {
        let peer = Peer()
        let first = Track()
        let refused = Track()
        let gate = Gate()
        peer.exchange.submit(
            .init(frame(0xb8, payload: [1]), name: "entered"), event: first.receive)
        peer.decision = { packet, _ in
            #expect(packet.payload == [2])
            if beforeRefusal { peer.exchange.receive(frame(0xb8, seq: 0)) }
            gate.revoke()
            return .skipped
        }
        peer.exchange.submit(
            .init(
                frame(0xb8, payload: [2]), name: "refused",
                admission: .init(owner: peer.owner, isCurrent: { gate.isCurrent })),
            event: refused.receive)
        if !beforeRefusal { peer.exchange.receive(frame(0xb8, seq: 0)) }
        #expect(peer.writes.map(\.payload) == [[1]])
        #expect(first.stages == [.sent, .acknowledged])
        #expect(first.settlements == [true])
        #expect(refused.stages == [.notSent])
        #expect(refused.settlements == [false])
        #expect(refused.failures == 1)
        peer.advance(to: 5)
        #expect(peer.writes.count == 1)
    }

    @Test func reentrantPendingSameKeyAndEnteredUnrelatedSuccessorSurviveRefusal() {
        let peer = Peer()
        let first = Track()
        let pending = Track()
        let other = Track()
        let refused = Track()
        peer.exchange.submit(
            .init(frame(0xb8, payload: [1]), name: "entered"), event: first.receive)
        peer.exchange.submit(.init(frame(1, payload: [9]), name: "other predecessor"))
        peer.decision = { _, _ in
            peer.exchange.receive(frame(1, seq: 1))
            peer.exchange.submit(
                .init(frame(1, payload: [10]), name: "other successor"), event: other.receive)
            peer.exchange.submit(
                .init(frame(0xb8, payload: [3]), name: "pending", coalesce: true),
                event: pending.receive)
            return .skipped
        }
        peer.exchange.submit(
            .init(
                frame(0xb8, payload: [2]), name: "refused",
                admission: .init(owner: peer.owner, isCurrent: { true })), event: refused.receive)
        peer.exchange.receive(frame(1, seq: 2))
        peer.exchange.receive(frame(0xb8, seq: 0))
        peer.advance(to: 0.049)
        #expect(peer.writes.map(\.payload) == [[1], [9], [10]])
        peer.advance(to: 0.05)
        #expect(peer.writes.map(\.payload) == [[1], [9], [10], [3]])
        peer.exchange.receive(frame(0xb8, seq: 3))
        #expect(first.stages == [.sent, .acknowledged])
        #expect(other.stages == [.sent, .acknowledged])
        #expect(pending.stages == [.sent, .acknowledged])
        #expect(refused.stages == [.notSent])
    }

    @Test func reentrantEnteredSameKeySuccessorCannotBeRolledBack() {
        let peer = Peer()
        let first = Track()
        let successor = Track()
        let refused = Track()
        peer.exchange.submit(
            .init(frame(0xb8, payload: [1]), name: "entered"), event: first.receive)
        peer.decision = { _, _ in
            peer.exchange.submit(
                .init(frame(0xb8, payload: [3]), name: "successor"), event: successor.receive)
            return .skipped
        }
        peer.exchange.submit(
            .init(
                frame(0xb8, payload: [2]), name: "refused",
                admission: .init(owner: peer.owner, isCurrent: { true })), event: refused.receive)
        peer.exchange.receive(frame(0xb8, seq: 0))
        #expect(first.stages == [.sent])
        peer.exchange.receive(frame(0xb8, seq: 1))
        #expect(successor.stages == [.sent, .acknowledged])
        #expect(peer.writes.map(\.payload) == [[1], [3]])
        #expect(refused.stages == [.notSent])
    }

    @Test func nestedRefusedSameKeyWritesReplayTheEnteredPredecessorACK() {
        let peer = Peer()
        let first = Track()
        let outer = Track()
        let inner = Track()
        peer.exchange.submit(
            .init(frame(0xb8, payload: [1]), name: "entered"), event: first.receive)
        peer.decision = { packet, _ in
            if packet.payload == [2] {
                peer.exchange.submit(
                    .init(
                        frame(0xb8, payload: [3]), name: "inner refused",
                        admission: .init(owner: peer.owner, isCurrent: { true })),
                    event: inner.receive)
            } else {
                peer.exchange.receive(frame(0xb8, seq: 0))
            }
            return .skipped
        }
        peer.exchange.submit(
            .init(
                frame(0xb8, payload: [2]), name: "outer refused",
                admission: .init(owner: peer.owner, isCurrent: { true })), event: outer.receive)
        #expect(first.stages == [.sent, .acknowledged])
        #expect(outer.stages == [.notSent])
        #expect(inner.stages == [.notSent])
        #expect(peer.writes.map(\.payload) == [[1]])
    }

    @Test func receiptRetirementSkipsAnUnsentRetryButPreservesEnteredZeroSequenceACK() {
        let peer = Peer()
        let track = Track()
        let gate = Gate()
        peer.exchange.submit(
            .init(
                frame(), name: "admitted",
                admission: .init(owner: peer.owner, isCurrent: { gate.isCurrent })),
            event: track.receive)
        #expect(peer.writes.count == 1)
        gate.revoke()
        peer.advance(to: 0.3)
        #expect(peer.writes.count == 1)
        peer.exchange.receive(frame(seq: 0))
        #expect(track.stages == [.sent, .acknowledged])
        #expect(track.settlements == [true])
        peer.exchange.retire(CancellationError(), notifySets: true)
        peer.advance(to: 5)
        #expect(peer.writes.count == 1)
    }

    @Test func sourceABARefusesPendingReceiptWithoutErasingAYoungerDirectSend() {
        let peer = Peer()
        let first = Track()
        let old = Track()
        let direct = Track()
        peer.exchange.submit(.init(frame(payload: [1]), name: "entered"), event: first.receive)
        peer.exchange.submit(
            .init(
                frame(payload: [2]), name: "old pending", coalesce: true,
                admission: .init(owner: peer.owner, isCurrent: { true })), event: old.receive)
        peer.owner.replaceSource()
        peer.exchange.receive(frame(seq: 0))
        peer.advance(to: 0.1)
        #expect(old.stages == [.notSent])
        #expect(peer.writes.map(\.payload) == [[1]])
        peer.exchange.submit(
            .init(frame(payload: [3]), name: "direct successor"), event: direct.receive)
        peer.exchange.receive(frame(seq: 1))
        #expect(direct.stages == [.sent, .acknowledged])
        #expect(first.stages == [.sent, .acknowledged])
    }

    @Test func retiredAdmissionDecisionCannotReplayAnOldACKIntoANewGeneration() {
        let peer = Peer()
        let next = Track()
        let refused = Track()
        peer.exchange.submit(.init(frame(0xb8, payload: [1]), name: "entered"))
        peer.decision = { _, _ in
            peer.exchange.receive(frame(0xb8, seq: 0))
            peer.exchange.retire(CancellationError())
            peer.sequence = 0
            peer.exchange.submit(
                .init(frame(0xb8, payload: [3]), name: "new source"), event: next.receive)
            return .skipped
        }
        peer.exchange.submit(
            .init(
                frame(0xb8, payload: [2]), name: "refused",
                admission: .init(owner: peer.owner, isCurrent: { true })), event: refused.receive)
        #expect(next.stages == [.sent])
        #expect(refused.stages == [.notSent])
        peer.exchange.receive(frame(0xb8, seq: 0))
        #expect(next.stages == [.sent, .acknowledged])
        #expect(peer.writes.map(\.payload) == [[1], [3]])
    }

    @Test func missingAdmittedEndpointRefusesWhileTheOriginalDirectEndpointStillWrites() {
        let peer = Peer()
        let refused = Track()
        peer.exchange.endpoint.writeAdmittedDatalink = nil
        peer.exchange.submit(
            .init(
                frame(payload: [1]), name: "supplied",
                admission: .init(owner: peer.owner, isCurrent: { true })), event: refused.receive)
        #expect(peer.writes.isEmpty)
        #expect(refused.stages == [.notSent])
        peer.exchange.submit(.init(frame(payload: [2]), name: "direct"))
        #expect(peer.writes.map(\.payload) == [[2]])
    }

    private func frame(_ cmd: UInt8 = 1, seq: UInt16 = 0, payload: [UInt8] = [0]) -> Duml.Frame {
        .init(
            sender: 1, receiver: 2, seq: seq, flags: Duml.flagResponse,
            cmdSet: 2, cmdId: cmd, payload: payload)
    }

    @MainActor private final class Track {
        var stages: [ControlWireEvent] = []
        var settlements: [Bool] = []
        var failures = 0
        func receive(_ event: DjiAppleControlExchange.SetEvent) {
            switch event {
            case .stage(let value): stages.append(value)
            case .settled(let value): settlements.append(value)
            case .failed: failures += 1
            }
        }
    }
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        var isCurrent: Bool {
            lock.lock()
            defer { lock.unlock() }
            return active
        }
        func revoke() {
            lock.lock()
            active = false
            lock.unlock()
        }
    }
    /// SIMULATED semantic peer uses the actual production queue and native admission port.
    @MainActor private final class Peer {
        let owner = DJICommandOwner()
        var time: TimeInterval = 0
        var sequence: UInt16 = 0
        var writes: [Duml.Frame] = []
        var wakes: [(TimeInterval, @MainActor @Sendable () -> Void)] = []
        var decision: ((Duml.Frame, DJICommandAdmission) -> DjiAppleCommandWrite)?
        lazy var exchange = DjiAppleControlExchange(
            endpoint: .init(
                writeDatalink: { [unowned self] in write($0) },
                writeAdmittedDatalink: { [unowned self] packet, admission in
                    if let decision { return decision(packet, admission) }
                    guard admission.admits(owner) else { return .skipped }
                    return write(packet)
                }),
            timing: .init(
                now: { [unowned self] in time },
                schedule: { [unowned self] delay, wake in
                    let parts = delay.components
                    wakes.append(
                        (time + Double(parts.seconds) + Double(parts.attoseconds) / 1e18, wake))
                }), context: { .init(canTransmit: true) })
        func write(_ packet: Duml.Frame) -> DjiAppleCommandWrite {
            writes.append(packet)
            defer { sequence &+= 1 }
            return .queued(sequence)
        }
        func advance(to deadline: TimeInterval) {
            while let next = wakes.enumerated().filter({ $0.element.0 <= deadline + 1e-12 })
                .min(by: { $0.element.0 < $1.element.0 })
            {
                time = next.element.0
                wakes.remove(at: next.offset)
                next.element.1()
            }
            time = deadline
        }
    }
}
