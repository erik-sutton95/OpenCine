import Foundation
import Testing

import OpenCineStreaming

@Suite struct StreamSendQueueTests {
    private func bytes(_ count: Int) -> [UInt8] { Array(repeating: 1, count: count) }
    private func annex(_ count: Int) -> [UInt8] { [0, 0, 0, 1] + Array(repeating: 2, count: count - 4) }
    private func key(_ ms: UInt32, _ size: Int = 800) -> StreamMediaPacket {
        .video(annexB: annex(size), isKeyframe: true, decodeMs: ms, presentMs: ms)
    }
    private func inter(_ ms: UInt32, _ size: Int = 800) -> StreamMediaPacket {
        .video(annexB: annex(size), isKeyframe: false, decodeMs: ms, presentMs: ms)
    }
    private func drain(_ q: inout StreamSendQueue) -> [StreamMediaPacket] {
        var out: [StreamMediaPacket] = []
        while let p = q.next() { out.append(p) }
        return out
    }

    @Test func passesPacketsInOrderWhenThereIsRoom() {
        var q = StreamSendQueue(maxBytes: 10_000)
        let packets: [StreamMediaPacket] = [.audio(raw: bytes(10), presentMs: 0), key(0), inter(33)]
        packets.forEach { q.enqueue($0) }
        #expect(q.queuedBytes == 1_610)
        #expect(drain(&q) == packets)
        #expect(q.queuedBytes == 0)
    }

    @Test func dropsOldestWholeVideoGroupBeforeAudio() {
        var q = StreamSendQueue(maxBytes: 2_000)
        q.enqueue(.audio(raw: bytes(100), presentMs: 0))
        q.enqueue(key(0))
        q.enqueue(inter(33))
        q.enqueue(key(66))
        #expect(q.droppedVideoGroups == 1)
        #expect(q.droppedAudioPackets == 0)
        #expect(drain(&q) == [.audio(raw: bytes(100), presentMs: 0), key(66)])
    }

    @Test func configIsNeverDropped() {
        var q = StreamSendQueue(maxBytes: 1_000)
        q.enqueue(.videoConfig(sps: bytes(300), pps: bytes(100)))
        q.enqueue(.audioConfig(audioSpecificConfig: bytes(300)))
        q.enqueue(.audio(raw: bytes(200), presentMs: 0))
        q.enqueue(key(0))
        q.enqueue(.audio(raw: bytes(200), presentMs: 21))
        let out = drain(&q)
        #expect(Array(out.prefix(2)) == [.videoConfig(sps: bytes(300), pps: bytes(100)), .audioConfig(audioSpecificConfig: bytes(300))])
        #expect(q.droppedVideoGroups == 1)
    }

    @Test func nextVideoOutAfterADropIsAKeyframe() {
        var q = StreamSendQueue(maxBytes: 1_000)
        q.enqueue(key(0))
        q.enqueue(inter(33))  // overflows: the open group goes
        q.enqueue(inter(66, 100))  // belongs to the dropped group, so it may not go out alone
        q.enqueue(key(100))
        q.enqueue(inter(133, 100))
        #expect(drain(&q) == [key(100), inter(133, 100)])
        #expect(q.droppedVideoGroups == 1)
    }

    @Test func staysWithinMaxBytesWhenOnlyAudioIsQueued() {
        var q = StreamSendQueue(maxBytes: 500)
        for ms in stride(from: UInt32(0), to: 210, by: 21) { q.enqueue(.audio(raw: bytes(100), presentMs: ms)) }
        #expect(q.queuedBytes <= 500)
        #expect(q.droppedAudioPackets == 5)
        #expect(q.next() == .audio(raw: bytes(100), presentMs: 105))
    }

    @Test func queuedDurationSpansTheQueuedMedia() {
        var q = StreamSendQueue(maxBytes: 100_000)
        #expect(q.queuedDuration == .zero)
        q.enqueue(.audio(raw: bytes(10), presentMs: 1_000))
        q.enqueue(key(1_100))
        q.enqueue(.audio(raw: bytes(10), presentMs: 2_500))
        #expect(q.queuedDuration == .milliseconds(1_500))
    }
}
