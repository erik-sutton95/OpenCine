#if canImport(os)
import Foundation
import OpenCineDJI
import OpenCineMedia
import os

/// HEVC reassembly on the UDP queue. Main hops only complete access units (~25 Hz),
/// not every SoftAP datagram.
final class SoftAPVideoAssembler: Sendable {
    /// Complete AUs held for the main actor: 2 s at 25 fps. The old cap of 8
    /// (320 ms) turned an ordinary main-thread hitch into reference loss, and
    /// Pocket only sends the next keyframe when asked.
    static let pendingLimit = 50

    struct Delivery {
        let accessUnits: [[UInt8]]
        let discontinuity: Bool
        let awaitingRandomAccess: Bool

        /// A retained old IRAP can paint, but cannot repair missing references
        /// after it. A current IRAP suffix, conversely, restores those references.
        /// Keep the same ordering for production and decoder integration tests.
        @MainActor
        func deliver(
            onDiscontinuity: () -> Void,
            onAccessUnit: ([UInt8]) -> Void
        ) {
            if discontinuity, !awaitingRandomAccess { onDiscontinuity() }
            for accessUnit in accessUnits { onAccessUnit(accessUnit) }
            if discontinuity, awaitingRandomAccess { onDiscontinuity() }
        }
    }

    struct Snapshot {
        var packets = 0
        var dropped = 0
        var lastPacket: Date?
        var lastAU: Date?
        var accessUnits = 0
    }

    struct Ingest {
        var accessUnit: [UInt8]?
        var firstPacket = false
        var shouldHop = false
        var droppedPending = 0
    }

    private struct State: Sendable {
        var depacketizer = HevcDepacketizer()
        var codec: LiveVideoCodec?
        var packets = 0
        var accessUnits = 0
        var lastPacket: Date?
        var lastAU: Date?
        var loggedFirst = false
        var peerCursor: UInt16 = 0
        var hasVideoSeq = false
        /// Telemetry-seeded group 0 before the first `0x02`. Distinct from
        /// `hasVideoSeq` so later `0x01` cannot rewind after video is seen.
        var hasGroup0 = false
        var pending: [[UInt8]] = []
        var awaitingRandomAccess = false
        var discontinuity = false
        var incompleteSeen = 0
        var hopScheduled = false
        var pendingSince: TimeInterval?
        var pendingPeak = 0
        var pendingDrops = 0
        var previousIncomplete = 0
        var maximumDeliveryWait: TimeInterval = 0
        var packetTiming = DeliveryCadence(startedAt: ProcessInfo.processInfo.systemUptime)
        var accessUnitTiming = DeliveryCadence(startedAt: ProcessInfo.processInfo.systemUptime)
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func ingest(_ datagram: [UInt8]) -> Ingest {
        lock.withLock { state in
            let now = ProcessInfo.processInfo.systemUptime
            state.packets += 1
            state.packetTiming.note(at: now)
            state.lastPacket = Date()
            if let seq = DumlTransport.transportSeq(datagram) {
                state.peerCursor = seq
                state.hasVideoSeq = true
                state.hasGroup0 = true
            }
            let first = !state.loggedFirst
            if first { state.loggedFirst = true }
            let au = state.depacketizer.feed(datagram)
            var shouldHop = false
            var droppedPending = 0
            if state.depacketizer.droppedIncomplete > state.incompleteSeen {
                // Queued AUs completed before the gap and still decode; one may be
                // the keyframe that repairs it. Only later dependants are lost.
                state.incompleteSeen = state.depacketizer.droppedIncomplete
                state.awaitingRandomAccess = true
                state.discontinuity = true
            }
            if let au {
                state.accessUnitTiming.note(at: now)
                if state.codec == nil { state.codec = LiveVideo.detect(annexB: au) }
                state.accessUnits += 1
                state.lastAU = Date()
                let codec = state.codec ?? .hevc
                let randomAccess = Self.hasRandomAccess(au, codec: codec)
                if randomAccess { state.awaitingRandomAccess = false }
                if !state.awaitingRandomAccess
                    || LiveVideo.accessUnitCarriesKeyframe(au, codec: codec)
                {
                    state.pending.append(au)
                } else {
                    droppedPending += 1
                }
                if state.pendingSince == nil { state.pendingSince = now }
                if state.pending.count > Self.pendingLimit {
                    // Keep a complete independently decodable suffix. Removing
                    // arbitrary P-frames leaves their dependants undecodable.
                    let lastIRAP = state.pending.lastIndex {
                        Self.hasRandomAccess($0, codec: codec)
                    }
                    if let lastIRAP, state.pending.count - lastIRAP <= Self.pendingLimit {
                        droppedPending += lastIRAP
                        state.pending.removeFirst(lastIRAP)
                    } else {
                        let retained = state.pending.last {
                            LiveVideo.accessUnitCarriesKeyframe($0, codec: codec)
                        }
                        droppedPending += state.pending.count - (retained == nil ? 0 : 1)
                        state.pending = retained.map { [$0] } ?? []
                        state.awaitingRandomAccess = true
                    }
                    state.discontinuity = true
                }
                state.pendingDrops += droppedPending
                state.pendingPeak = max(state.pendingPeak, state.pending.count)
                if !state.hopScheduled {
                    state.hopScheduled = true
                    shouldHop = true
                }
            }
            if state.discontinuity, !state.hopScheduled {
                state.hopScheduled = true
                shouldHop = true
            }
            return Ingest(
                accessUnit: au, firstPacket: first, shouldHop: shouldHop,
                droppedPending: droppedPending)
        }
    }

    private static func hasRandomAccess(_ au: [UInt8], codec: LiveVideoCodec) -> Bool {
        Hevc.nalHeaders(au).contains { byte in
            codec == .avc ? Avc.nalType(byte) == Avc.idr : Hevc.isIRAP(Hevc.nalType(byte))
        }
    }

    func takePending() -> [[UInt8]] { takeDelivery().accessUnits }

    func takeDelivery() -> Delivery {
        lock.withLock { state in
            if let pendingSince = state.pendingSince {
                state.maximumDeliveryWait = max(
                    state.maximumDeliveryWait,
                    ProcessInfo.processInfo.systemUptime - pendingSince)
            }
            state.pendingSince = nil
            let aus = state.pending
            let discontinuity = state.discontinuity
            state.discontinuity = false
            state.pending.removeAll(keepingCapacity: true)
            state.hopScheduled = false
            return Delivery(
                accessUnits: aus, discontinuity: discontinuity,
                awaitingRandomAccess: state.awaitingRandomAccess)
        }
    }

    var hasPending: Bool {
        lock.withLock { !$0.pending.isEmpty }
    }

    func takeDeliveryWindow(at now: TimeInterval) -> String {
        lock.withLock { state in
            let video = state.packetTiming.takeWindow(at: now)
            let au = state.accessUnitTiming.takeWindow(at: now)
            let waiting = state.pendingSince.map { max(0, now - $0) } ?? 0
            let wait = max(waiting, state.maximumDeliveryWait)
            let incomplete = state.depacketizer.droppedIncomplete
            let dropped = max(0, incomplete - state.previousIncomplete)
            let summary =
                "videoHz=\(String(format: "%.1f", video?.hertz ?? 0)) "
                + "videoGapMs=\(Int(video?.maximumGapMilliseconds ?? 0)) "
                + "auHz=\(String(format: "%.1f", au?.hertz ?? 0)) "
                + "auGapMs=\(Int(au?.maximumGapMilliseconds ?? 0)) "
                + "mainWaitMs=\(Int(wait * 1_000)) pendingPeak=\(state.pendingPeak) "
                + "queueDrop=\(state.pendingDrops) incompleteDrop=\(dropped)"
            state.previousIncomplete = incomplete
            state.pendingPeak = state.pending.count
            state.pendingDrops = 0
            state.maximumDeliveryWait = 0
            return summary
        }
    }

    var incidentQueue: DjiAppleQueueObservation {
        lock.withLock { state in
            DjiAppleQueueObservation(
                bytes: state.pending.reduce(0) { $0 + $1.count }, count: state.pending.count,
                ageMilliseconds: state.pendingSince.map {
                    max(0, ProcessInfo.processInfo.systemUptime - $0) * 1_000
                },
                incompleteAccessUnits: state.depacketizer.droppedIncomplete,
                drops: state.pendingDrops)
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock { state in
            Snapshot(
                packets: state.packets,
                dropped: state.depacketizer.droppedIncomplete,
                lastPacket: state.lastPacket,
                lastAU: state.lastAU,
                accessUnits: state.accessUnits
            )
        }
    }

    func peerCursor(fallback: UInt16) -> UInt16 {
        lock.withLock { state in
            DumlTransport.AckWindows.windowCursor(
                stored: state.peerCursor, seen: state.hasGroup0, fallback: fallback)
        }
    }

    /// Seed group 0 from telemetry only before the first `0x02`.
    @discardableResult
    func seedPeerCursorIfNeeded(_ cursor: UInt16) -> Bool {
        lock.withLock { state in
            guard
                DumlTransport.AckWindows.shouldSeedVideoCursorFromTelemetry(
                    hasVideoSeq: state.hasVideoSeq)
            else { return false }
            state.peerCursor = cursor
            state.hasGroup0 = true
            return true
        }
    }

    func reset() {
        lock.withLock { $0 = State() }
    }

    /// First `armLiveVideo` must drop leftover GOP bytes without wiping the
    /// ACK video cursor (that left 40 Hz group0=0 until the next 0x02).
    func resetDepacketizerKeepingCursor() {
        lock.withLock { state in
            let cursor = state.peerCursor
            let has = state.hasVideoSeq
            let group0 = state.hasGroup0
            state = State()
            state.peerCursor = cursor
            state.hasVideoSeq = has
            state.hasGroup0 = group0
        }
    }

    /// Clear receive clocks. Stamping `Date()` looked like a live packet and
    /// reset the feed watchdog to idle, which then rebuilt again at 2s.
    func noteRebuild() {
        lock.withLock {
            $0.lastPacket = nil
            $0.lastAU = nil
            $0.depacketizer.reset()
            $0.pending.removeAll()
            $0.hopScheduled = false
            $0.pendingSince = nil
            $0.previousIncomplete = 0
            $0.incompleteSeen = 0
            $0.awaitingRandomAccess = false
            $0.discontinuity = false
        }
    }
}

#endif
