import Testing

@testable import OpenCineDJI

@Suite("Refused DJI registration restores only its exact opcode")
struct CameraSetMailboxAdmissionTests {
    @Test func refusalRestoresOnlyRegisteredKeyAndKeepsUnrelatedACK() {
        let key: UInt16 = 0x02b8
        let other: UInt16 = 0x0201
        var mailbox = CameraSetMailbox()
        mailbox.beginLaunch(key: key, now: 0)
        mailbox.noteTransmit(key: key, seq: 0)
        mailbox.beginLaunch(key: other, now: 0)
        mailbox.noteTransmit(key: other, seq: 30)
        let previous = mailbox
        mailbox.beginLaunch(key: key, now: 0.05)
        let expected = mailbox
        let ack = mailbox.decideAck(key: other, seq: 30)
        #expect(ack == .accept)
        mailbox.beginLaunch(key: other, now: 0.06)
        mailbox.noteTransmit(key: other, seq: 31)
        let restored = mailbox.restore(key: key, from: previous, ifUnchanged: expected)
        #expect(restored)
        #expect(mailbox.isOpenSeq(other, seq: 31))
        let predecessor = mailbox.decideAck(key: key, seq: 0)
        #expect(predecessor == .accept)
        let successor = mailbox.decideAck(key: other, seq: 31)
        #expect(successor == .accept)
    }

    @Test func newerSameKeyLaunchCannotBeRestored() {
        let key = CameraSetMailbox.zoomOpcodeKey
        var mailbox = CameraSetMailbox()
        mailbox.beginLaunch(key: key, now: 0)
        mailbox.noteTransmit(key: key, seq: 0)
        let previous = mailbox
        mailbox.beginLaunch(key: key, now: 0.05)
        let expected = mailbox
        mailbox.beginLaunch(key: key, now: 0.1)
        mailbox.noteTransmit(key: key, seq: 2)
        let restored = mailbox.restore(key: key, from: previous, ifUnchanged: expected)
        #expect(!restored)
        let old = mailbox.decideAck(key: key, seq: 0)
        #expect(old == .dropSuperseded)
        let new = mailbox.decideAck(key: key, seq: 2)
        #expect(new == .accept)
    }

    @Test func sameKeyACKTransitionCannotBeRestored() {
        let key = CameraSetMailbox.zoomOpcodeKey
        var mailbox = CameraSetMailbox()
        mailbox.beginLaunch(key: key, now: 0)
        mailbox.noteTransmit(key: key, seq: 0)
        let previous = mailbox
        mailbox.beginLaunch(key: key, now: 0.05)
        mailbox.noteTransmit(key: key, seq: 1)
        let expected = mailbox
        let ack = mailbox.decideAck(key: key, seq: 1)
        #expect(ack == .accept)
        let restored = mailbox.restore(key: key, from: previous, ifUnchanged: expected)
        #expect(!restored)
        #expect(!mailbox.hasOpen(key))
    }

    @Test func pendingSuccessorRequiresExplicitPreservation() {
        let key = CameraSetMailbox.zoomOpcodeKey
        var mailbox = CameraSetMailbox()
        mailbox.beginLaunch(key: key, now: 0)
        mailbox.noteTransmit(key: key, seq: 0)
        let previous = mailbox
        mailbox.beginLaunch(key: key, now: 0.05)
        let expected = mailbox
        let offered = mailbox.offer(key: key, urgent: false, now: 0.05)
        #expect(offered == .coalescePending)
        let strict = mailbox.restore(key: key, from: previous, ifUnchanged: expected)
        #expect(!strict)
        let preserved = mailbox.restore(
            key: key, from: previous, ifUnchanged: expected, preservingPending: true)
        #expect(preserved)
        let ack = mailbox.decideAck(key: key, seq: 0)
        #expect(ack == .accept)
        let next = mailbox.pendingLaunch(key: key, now: 0.05)
        #expect(next == .immediate)
    }
}
