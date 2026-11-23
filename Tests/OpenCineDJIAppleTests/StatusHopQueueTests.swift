#if canImport(os)
import Foundation
import OpenCineDJI
import Testing

@testable import OpenCineDJIApple

/// Status datagrams reach main in one hop per backlog. SIMULATED frames; no socket.
@Suite struct StatusHopQueueTests {
    private final class Socket: Sendable {}
    private let socket = Socket()

    /// A backlog of datagrams costs one main-actor hop, and the next datagram after the
    /// drain asks for a new one.
    @Test func aBacklogSchedulesOneHopAndTheNextDatagramAnother() {
        let queue = StatusHopQueue()
        #expect(queue.offer(datagram([status(1)])))
        #expect(!queue.offer(datagram([status(2)])))
        #expect(!queue.offer(datagram([status(3)])))
        #expect(queue.drain { _ in true }.flatMap(\.frames).map(\.seq) == [1, 2, 3])
        #expect(queue.drain { _ in true }.isEmpty)
        #expect(queue.offer(datagram([status(4)])))
    }

    /// Only the newest gimbal attitude push of a drain reaches main; every other frame keeps
    /// its arrival order, including frames that shared a datagram with a dropped push.
    @Test func aDrainKeepsOnlyTheNewestAttitudePushAndEveryOtherFrame() {
        let queue = StatusHopQueue()
        _ = queue.offer(datagram([attitude(1), status(2)]))
        _ = queue.offer(datagram([attitude(3)]))
        _ = queue.offer(datagram([status(4), attitude(5), reply(6)]))
        _ = queue.offer(datagram([status(7)]))
        let drained = queue.drain { _ in true }
        #expect(drained.map { $0.frames.map(\.seq) } == [[2], [], [4, 5, 6], [7]])
        // A single push per drain is delivered as is.
        _ = queue.offer(datagram([attitude(8)]))
        #expect(queue.drain { _ in true }.flatMap(\.frames).map(\.seq) == [8])
    }

    /// Datagrams from a retired socket generation are dropped before the newest attitude push
    /// is chosen, so a stale push can never hide the current one.
    @Test func staleGenerationsAreDroppedBeforeCoalescing() {
        let queue = StatusHopQueue()
        _ = queue.offer(datagram([attitude(1)], generation: 1))
        _ = queue.offer(datagram([attitude(2)], generation: 2))
        _ = queue.offer(datagram([status(3)], generation: 1))
        let drained = queue.drain { $0.generation == 2 }
        #expect(drained.flatMap(\.frames).map(\.seq) == [2])
    }

    private func datagram(_ frames: [Duml.Frame], generation: Int = 1) -> StatusHopQueue.Datagram {
        .init(bytes: [], frames: frames, mediaAdmission: nil, generation: generation, socket: socket)
    }

    private func frame(_ seq: UInt16, set: UInt8, id: UInt8, flags: UInt8 = 0) -> Duml.Frame {
        .init(sender: 0x04, receiver: 0x02, seq: seq, flags: flags, cmdSet: set, cmdId: id, payload: [0])
    }

    private func attitude(_ seq: UInt16) -> Duml.Frame { frame(seq, set: 0x04, id: 0x05) }
    private func status(_ seq: UInt16) -> Duml.Frame { frame(seq, set: 0x02, id: 0xDC) }
    private func reply(_ seq: UInt16) -> Duml.Frame {
        frame(seq, set: 0x04, id: 0x50, flags: Duml.flagResponse)
    }
}
#endif
