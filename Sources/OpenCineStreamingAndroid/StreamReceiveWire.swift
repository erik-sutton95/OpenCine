import Foundation
import OpenCineStreaming

/// Owner-keyed Android bridge over the portable `RTMPReceiveSession`, so the Android listener runs
/// the same server side of RTMP (handshake, commands, the expected-key rule, tag parsing) as iOS.
///
/// Every feed returns one binary reply (`Fixtures/rtmp-receive-reply-vectors.tsv`), big-endian:
/// u32 outbound length, the bytes to write back, u16 event count, then events as u8 kind, u32 body
/// length, body:
///
/// - `1` publish (under the expected key)
/// - `2` video config: u8 codec (0 AVC, 1 HEVC), u8 enhanced, configuration record
/// - `3` video frame: u8 codec, u8 keyframe, u32 decode ms, i32 composition ms, length-prefixed NAL units
/// - `4` audio config: AudioSpecificConfig
/// - `5` audio frame: u32 timestamp ms, raw AAC
/// - `6` unpublished
/// - `7` failed: the `RTMPReceiveFailure` case name, UTF-8 (never the key)
/// - `9` video end
/// - `10` closed: the session is over; close the connection
///
/// The token enters only through `create`; no reply ever carries it. An unknown owner answers
/// with a closed reply.
public final class StreamReceiveWire: @unchecked Sendable {
    public static let shared = StreamReceiveWire()

    private let lock = NSLock()
    private var sessions: [String: RTMPReceiveSession] = [:]

    public init() {}

    /// A session that accepts only `token` as the stream key; returns its owner id.
    public func create(token: String) -> String {
        let owner = UUID().uuidString
        lock.withLock { sessions[owner] = RTMPReceiveSession(expectedStreamKey: token) }
        return owner
    }

    public func feed(owner: String, bytes: [UInt8]) -> [UInt8] {
        let result = lock.withLock { () -> (RTMPReceiveSession.Output, Bool)? in
            guard var session = sessions[owner] else { return nil }
            let output = session.receive(bytes)
            sessions[owner] = session
            return (output, session.state == .closed)
        }
        guard let (output, closed) = result else { return Self.encode(RTMPReceiveSession.Output(), closed: true) }
        return Self.encode(output, closed: closed)
    }

    public func close(owner: String) {
        _ = lock.withLock { sessions.removeValue(forKey: owner) }
    }

    static func encode(_ output: RTMPReceiveSession.Output, closed: Bool) -> [UInt8] {
        var events: [(UInt8, [UInt8])] = []
        for event in output.events {
            switch event {
            case .publish: events.append((1, []))
            case .videoConfig(let codec, let record, let enhanced):
                events.append((2, [codec == .hevc ? 1 : 0, enhanced ? 1 : 0] + record))
            case .videoFrame(let frame):
                events.append(
                    (3, [frame.codec == .hevc ? 1 : 0, frame.keyframe ? 1 : 0] + u32(frame.decodeMs)
                        + u32(UInt32(bitPattern: frame.compositionMs)) + frame.data))
            case .audioConfig(let config): events.append((4, config))
            case .audioFrame(let timestamp, let bytes): events.append((5, u32(timestamp) + bytes))
            case .unpublished: events.append((6, []))
            case .failed(let failure): events.append((7, Array(name(failure).utf8)))
            case .videoEnd: events.append((9, []))
            default: break
            }
        }
        if closed { events.append((10, [])) }
        var out = u32(UInt32(output.outbound.count)) + output.outbound
        out += [UInt8(events.count >> 8 & 0xFF), UInt8(events.count & 0xFF)]
        for (kind, body) in events { out += [kind] + u32(UInt32(body.count)) + body }
        return out
    }

    private static func name(_ failure: RTMPReceiveFailure) -> String {
        switch failure {
        case .handshakeVersion: "handshakeVersion"
        case .chunkStream: "chunkStream"
        case .unexpectedStreamKey: "unexpectedStreamKey"
        }
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}
