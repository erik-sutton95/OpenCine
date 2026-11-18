import Foundation
import OpenCineCore

/// One stream from go-live to stop, without I/O: connection, reconnects, the send queue, the
/// encoder bitrate and the status the operator sees.
///
/// A platform shell applies the returned actions in order: it opens and closes the TLS connection,
/// writes bytes and reports each write's completion through `wrote(_:at:)`, sets the encoder's
/// bitrate, forces a keyframe, and calls `tick(at:)` at each `.wake` and about once a second while
/// live. Media published while the stream is not live is dropped, never queued; the latest codec
/// configuration is remembered and sent first whenever the stream goes live again.
public struct StreamRun: Sendable {
    public enum Action: Equatable, Sendable {
        /// Open a TLS connection; report `connected(at:)` or `connectionLost(at:)`.
        case connect(host: String, port: UInt16)
        case write([UInt8])
        /// Close the connection. Report nothing back.
        case disconnect
        case setVideoBitrate(Int)
        /// Encode the next picture as a keyframe.
        case requestKeyframe
        /// Call `tick(at:)` at this instant.
        case wake(at: MonotonicInstant)
    }

    public enum Phase: Equatable, Sendable {
        case connecting
        case live
        /// Waiting to reconnect, or connecting again; `attempt` counts from 1.
        case reconnecting(attempt: Int)
        case ended(End)
    }

    public enum End: Equatable, Sendable {
        case stopped
        /// The server refused the stream. The text holds no stream key.
        case refused(reason: String)
        /// The connection did not come back within the reconnect window.
        case gaveUp
    }

    public enum Health: Equatable, Sendable {
        case good
        /// The network is behind: the queue is over a second deep or video was dropped lately.
        case congested
        case offline
    }

    public struct Status: Equatable, Sendable {
        public var phase: Phase
        /// When the stream first went live; elapsed time counts from here.
        public var liveSince: MonotonicInstant?
        /// Bytes the network took over the last 2 seconds, in bits per second.
        public var sentBitrateBps: Int
        public var videoBitrateBps: Int
        public var droppedVideoGroups: Int
        public var droppedAudioPackets: Int
        public var health: Health
    }

    public private(set) var status: Status

    private static let sentWindow: Duration = .seconds(2)
    private static let congestedAfterDrop: Duration = .seconds(5)
    private static let behind: Duration = .seconds(1)

    private let destination: StreamDestination
    private let maxQueueBytes: Int
    private let maxInFlightBytes: Int
    private var session: RTMPPublishSession?
    private var queue: StreamSendQueue
    private var bitrate: StreamBitratePolicy
    private var reconnect: StreamReconnectPolicy
    private var videoConfig: StreamMediaPacket?
    private var audioConfig: StreamMediaPacket?
    private var inFlight = 0
    private var acknowledged: [(at: MonotonicInstant, bytes: Int)] = []
    private var wakeAt: MonotonicInstant?
    private var attempts = 0
    private var droppedGroupsBefore = 0
    private var droppedAudioBefore = 0
    private var lastDrop: MonotonicInstant?

    public init(
        destination: StreamDestination, format: StreamOutputFormat, now: MonotonicInstant,
        maxQueueBytes: Int = 4 * 1024 * 1024, maxInFlightBytes: Int = 256 * 1024
    ) {
        self.destination = destination
        self.maxQueueBytes = maxQueueBytes
        self.maxInFlightBytes = maxInFlightBytes
        queue = StreamSendQueue(maxBytes: maxQueueBytes)
        bitrate = StreamBitratePolicy(targetBps: format.videoBitrateBps, floorBps: format.videoBitrateBps / 3)
        reconnect = StreamReconnectPolicy(startedAt: now)
        status = Status(
            phase: .connecting, liveSince: nil, sentBitrateBps: 0, videoBitrateBps: format.videoBitrateBps,
            droppedVideoGroups: 0, droppedAudioPackets: 0, health: .offline)
    }

    private var isEnded: Bool { if case .ended = status.phase { true } else { false } }

    public mutating func start() -> [Action] {
        guard status.phase == .connecting, session == nil else { return [] }
        return [.connect(host: destination.host, port: destination.port)]
    }

    public mutating func connected(at now: MonotonicInstant) -> [Action] {
        guard !isEnded, session == nil else { return [] }
        var fresh = RTMPPublishSession(destination: destination)
        let hello = fresh.start()
        session = fresh
        return write(hello)
    }

    public mutating func received(_ bytes: [UInt8], at now: MonotonicInstant) -> [Action] {
        guard !isEnded, var current = session else { return [] }
        let output = current.receive(bytes)
        session = current
        var actions = write(output.outbound)
        for event in output.events {
            switch event {
            case .live:
                actions += wentLive(at: now)
            case .failed(.refused(let reason)):
                end(.refused(reason: reason))
                return actions + [.disconnect]
            case .failed(let failure):
                return actions + lost(failure, at: now)
            }
        }
        return actions
    }

    public mutating func connectionLost(at now: MonotonicInstant) -> [Action] {
        lost(nil, at: now)
    }

    public mutating func publish(_ packet: StreamMediaPacket, at now: MonotonicInstant) -> [Action] {
        switch packet {
        case .videoConfig: videoConfig = packet
        case .audioConfig: audioConfig = packet
        default: break
        }
        guard status.phase == .live else { return [] }
        queue.enqueue(packet)
        noteDrops(at: now)
        return drain() + observe(at: now)
    }

    public mutating func wrote(_ count: Int, at now: MonotonicInstant) -> [Action] {
        inFlight = max(0, inFlight - count)
        acknowledged.append((now, count))
        updateSent(at: now)
        guard status.phase == .live else { return [] }
        return drain() + observe(at: now)
    }

    public mutating func tick(at now: MonotonicInstant) -> [Action] {
        updateSent(at: now)
        if case .reconnecting = status.phase, let due = wakeAt {
            guard now >= due else { return [] }
            wakeAt = nil
            return [.connect(host: destination.host, port: destination.port)]
        }
        guard status.phase == .live else { return [] }
        return observe(at: now)
    }

    public mutating func stop(at now: MonotonicInstant) -> [Action] {
        guard !isEnded else { return [] }
        var goodbye: [UInt8] = []
        if var current = session {
            goodbye = current.close()
            session = nil
        }
        end(.stopped)
        return (goodbye.isEmpty ? [] : [.write(goodbye)]) + [.disconnect]
    }

    // MARK: Transitions

    private mutating func wentLive(at now: MonotonicInstant) -> [Action] {
        status.phase = .live
        status.liveSince = status.liveSince ?? now
        status.health = .good
        attempts = 0
        reconnect.wentLive()
        var actions: [Action] = []
        for config in [videoConfig, audioConfig].compactMap({ $0 }) {
            if let bytes = session?.send(config), !bytes.isEmpty {
                inFlight += bytes.count
                actions.append(.write(bytes))
            }
        }
        actions.append(.requestKeyframe)
        return actions
    }

    private mutating func lost(_ failure: StreamFailure?, at now: MonotonicInstant) -> [Action] {
        guard !isEnded else { return [] }
        session = nil
        inFlight = 0
        queue = StreamSendQueue(maxBytes: maxQueueBytes)
        droppedGroupsBefore = 0
        droppedAudioBefore = 0
        switch reconnect.decide(after: failure, at: now) {
        case .retry(let delay):
            attempts += 1
            status.phase = .reconnecting(attempt: attempts)
            status.health = .offline
            let due = now + delay
            wakeAt = due
            return [.disconnect, .wake(at: due)]
        case .giveUp:
            if case .refused(let reason) = failure { end(.refused(reason: reason)) } else { end(.gaveUp) }
            return [.disconnect]
        }
    }

    private mutating func end(_ reason: End) {
        status.phase = .ended(reason)
        status.health = .offline
        session = nil
        wakeAt = nil
        queue = StreamSendQueue(maxBytes: maxQueueBytes)
    }

    // MARK: Sending

    private mutating func write(_ bytes: [UInt8]) -> [Action] {
        guard !bytes.isEmpty else { return [] }
        inFlight += bytes.count
        return [.write(bytes)]
    }

    private mutating func drain() -> [Action] {
        guard var current = session else { return [] }
        var actions: [Action] = []
        while inFlight < maxInFlightBytes, let packet = queue.next() {
            let bytes = current.send(packet)
            guard !bytes.isEmpty else { continue }
            inFlight += bytes.count
            actions.append(.write(bytes))
        }
        session = current
        return actions
    }

    private mutating func noteDrops(at now: MonotonicInstant) {
        if queue.droppedVideoGroups > droppedGroupsBefore {
            status.droppedVideoGroups += queue.droppedVideoGroups - droppedGroupsBefore
            droppedGroupsBefore = queue.droppedVideoGroups
            lastDrop = now
        }
        if queue.droppedAudioPackets > droppedAudioBefore {
            status.droppedAudioPackets += queue.droppedAudioPackets - droppedAudioBefore
            droppedAudioBefore = queue.droppedAudioPackets
        }
    }

    private mutating func observe(at now: MonotonicInstant) -> [Action] {
        let behind = queue.queuedDuration
        let rate = bitrate.observe(queuedDuration: behind, at: now)
        let recentDrop = lastDrop.map { now - $0 < Self.congestedAfterDrop } ?? false
        status.health = behind > Self.behind || recentDrop ? .congested : .good
        guard rate != status.videoBitrateBps else { return [] }
        status.videoBitrateBps = rate
        return [.setVideoBitrate(rate)]
    }

    private mutating func updateSent(at now: MonotonicInstant) {
        acknowledged.removeAll { now - $0.at >= Self.sentWindow }
        let bytes = acknowledged.reduce(0) { $0 + $1.bytes }
        status.sentBitrateBps = bytes * 8 / 2
    }
}
