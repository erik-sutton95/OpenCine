import Foundation

/// The bounded queue between the encoders and a slow network.
///
/// When the queued media passes `maxBytes`, whole video groups go first, oldest first: a keyframe
/// and the frames that depend on it. Video that would follow a dropped group without its keyframe
/// is dropped too, so the next video out is always a keyframe. Audio goes only when no video is
/// left to drop. Codec configuration is never dropped. Latency therefore stays bounded instead of
/// growing with the backlog.
public struct StreamSendQueue: Sendable {
    public let maxBytes: Int
    public private(set) var queuedBytes = 0
    public private(set) var droppedVideoGroups = 0
    public private(set) var droppedAudioPackets = 0

    private var packets: [StreamMediaPacket] = []
    private var awaitingKeyframe = false

    public init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    public var isEmpty: Bool { packets.isEmpty }

    /// The media time from the oldest to the newest queued packet: how far behind the network is.
    public var queuedDuration: Duration {
        let times = packets.compactMap(\.mediaMs)
        guard let low = times.min(), let high = times.max() else { return .zero }
        return .milliseconds(Int64(high) - Int64(low))
    }

    public mutating func enqueue(_ packet: StreamMediaPacket) {
        if case .video(_, let isKeyframe, _, _) = packet {
            if awaitingKeyframe, !isKeyframe { return }
            awaitingKeyframe = false
        }
        packets.append(packet)
        queuedBytes += packet.byteCount
        while queuedBytes > maxBytes, dropOldestVideoGroup() || dropOldestAudio() {}
    }

    public mutating func next() -> StreamMediaPacket? {
        guard !packets.isEmpty else { return nil }
        let packet = packets.removeFirst()
        queuedBytes -= packet.byteCount
        return packet
    }

    private mutating func dropOldestVideoGroup() -> Bool {
        guard let first = packets.firstIndex(where: \.isFrame) else { return false }
        let nextKeyframe = packets[(first + 1)...].firstIndex { $0.isKeyframe }
        let end = nextKeyframe ?? packets.endIndex
        var kept: [StreamMediaPacket] = Array(packets[..<first])
        for packet in packets[first..<end] {
            if packet.isFrame { queuedBytes -= packet.byteCount } else { kept.append(packet) }
        }
        packets = kept + packets[end...]
        droppedVideoGroups += 1
        if nextKeyframe == nil { awaitingKeyframe = true }
        return true
    }

    private mutating func dropOldestAudio() -> Bool {
        guard let index = packets.firstIndex(where: \.isAudioFrame) else { return false }
        queuedBytes -= packets.remove(at: index).byteCount
        droppedAudioPackets += 1
        return true
    }
}

extension StreamMediaPacket {
    var byteCount: Int {
        switch self {
        case .videoConfig(let sps, let pps): sps.count + pps.count
        case .video(let annexB, _, _, _): annexB.count
        case .audioConfig(let config): config.count
        case .audio(let raw, _): raw.count
        }
    }

    /// A video frame, as opposed to its configuration.
    var isFrame: Bool { if case .video = self { true } else { false } }
    var isKeyframe: Bool { if case .video(_, true, _, _) = self { true } else { false } }
    var isAudioFrame: Bool { if case .audio = self { true } else { false } }

    var mediaMs: UInt32? {
        switch self {
        case .video(_, _, let decodeMs, _): decodeMs
        case .audio(_, let presentMs): presentMs
        case .videoConfig, .audioConfig: nil
        }
    }
}
