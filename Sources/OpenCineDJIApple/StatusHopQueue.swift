#if canImport(os)
import Foundation
import OpenCineDJI
import os

/// Status datagrams scanned on the UDP queue, waiting for one main-actor hop. A task per
/// datagram let a backlog (main busy during a feed repair) replay every gimbal attitude push on
/// main one after another. One hop drains the whole backlog in arrival order, and since an
/// attitude push (`0x04/0x05`) only overwrites pose and mode state, a drain keeps only the
/// newest one. Every other frame is delivered.
final class StatusHopQueue: Sendable {
    struct Datagram: Sendable {
        let bytes: [UInt8]
        var frames: [Duml.Frame]
        let mediaAdmission: DjiAppleMediaIngress?
        let generation: Int
        /// The receiving socket, held so a successor connection can never match a retired one.
        let socket: any AnyObject & Sendable
    }

    private struct State {
        var pending: [Datagram] = []
        var hopScheduled = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// Queues one datagram. `true` when the caller must schedule the hop that drains it.
    func offer(_ datagram: Datagram) -> Bool {
        lock.withLock { state in
            state.pending.append(datagram)
            if state.hopScheduled { return false }
            state.hopScheduled = true
            return true
        }
    }

    /// Everything queued since the last drain that `isCurrent` keeps, in arrival order, with
    /// older attitude pushes removed. The next offer schedules a new hop.
    func drain(isCurrent: (Datagram) -> Bool) -> [Datagram] {
        let pending = lock.withLock { state in
            state.hopScheduled = false
            defer { state.pending = [] }
            return state.pending
        }
        return Self.newestAttitudeOnly(pending.filter(isCurrent))
    }

    static func newestAttitudeOnly(_ datagrams: [Datagram]) -> [Datagram] {
        var keptAttitude = false
        var result = datagrams
        for index in result.indices.reversed() {
            var frames: [Duml.Frame] = []
            for frame in result[index].frames.reversed() {
                if frame.cmdSet == 0x04, frame.cmdId == 0x05 {
                    if keptAttitude { continue }
                    keptAttitude = true
                }
                frames.append(frame)
            }
            result[index].frames = frames.reversed()
        }
        return result
    }
}
#endif
