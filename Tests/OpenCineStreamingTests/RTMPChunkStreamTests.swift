import Foundation
import Testing

@testable import OpenCineStreaming

@Suite struct RTMPChunkStreamTests {
    private func message(
        csid: UInt32 = 3, type: UInt8 = 20, stream: UInt32 = 0, time: UInt32 = 0, size: Int, fill: UInt8 = 1
    ) -> RTMPMessage {
        RTMPMessage(
            chunkStreamID: csid, typeID: type, messageStreamID: stream, timestamp: time,
            payload: (0..<size).map { UInt8(truncatingIfNeeded: $0) &+ fill })
    }

    @Test func firstMessageIsType0HeaderExactly() {
        var w = RTMPChunkWriter()
        #expect(
            w.encode(RTMPMessage(chunkStreamID: 3, typeID: 20, messageStreamID: 0, timestamp: 1, payload: [0xAA]))
                == [0x03, 0, 0, 1, 0, 0, 1, 20, 0, 0, 0, 0, 0xAA])
    }

    @Test func messageStreamIDIsLittleEndian() {
        var w = RTMPChunkWriter()
        let out = w.encode(RTMPMessage(chunkStreamID: 4, typeID: 8, messageStreamID: 1, timestamp: 0, payload: [0]))
        #expect(Array(out[8..<12]) == [1, 0, 0, 0])
    }

    @Test func splitsAtChunkSizeWithType3Continuation() {
        var w = RTMPChunkWriter()
        w.chunkSize = 2
        let out = w.encode(RTMPMessage(chunkStreamID: 3, typeID: 8, messageStreamID: 1, timestamp: 0, payload: [1, 2, 3]))
        #expect(Array(out.suffix(4)) == [1, 2, 0xC3, 3])
    }

    @Test(arguments: [1, 128, 4096])
    func roundTripsAcrossChunkSizes(chunkSize: Int) throws {
        var w = RTMPChunkWriter()
        var r = RTMPChunkReader()
        w.chunkSize = chunkSize
        r.chunkSize = chunkSize
        let messages = [
            message(csid: 4, type: 8, stream: 1, time: 0, size: 300),
            message(csid: 6, type: 9, stream: 1, time: 0, size: 10_000, fill: 9),
            message(csid: 4, type: 8, stream: 1, time: 21, size: 300, fill: 3),
            message(csid: 6, type: 9, stream: 1, time: 33, size: 5, fill: 4),
            message(csid: 3, type: 20, stream: 0, time: 0, size: 0),
        ]
        var wire: [UInt8] = []
        for m in messages { wire += w.encode(m) }
        #expect(try r.push(wire) == messages)
    }

    @Test func interleavedChunksOfTwoStreamsReassemble() throws {
        // Chunks of csid 4 and csid 6 alternate on the wire; each message still reassembles.
        var r = RTMPChunkReader()
        r.chunkSize = 2
        let wire: [UInt8] =
            [0x04, 0, 0, 0, 0, 0, 3, 8, 1, 0, 0, 0, 0xA1, 0xA2]
            + [0x06, 0, 0, 0, 0, 0, 3, 9, 1, 0, 0, 0, 0xB1, 0xB2]
            + [0xC4, 0xA3] + [0xC6, 0xB3]
        #expect(try r.push(wire) == [
            RTMPMessage(chunkStreamID: 4, typeID: 8, messageStreamID: 1, timestamp: 0, payload: [0xA1, 0xA2, 0xA3]),
            RTMPMessage(chunkStreamID: 6, typeID: 9, messageStreamID: 1, timestamp: 0, payload: [0xB1, 0xB2, 0xB3]),
        ])
    }

    @Test func extendedTimestampRoundTrips() throws {
        var w = RTMPChunkWriter()
        w.chunkSize = 16
        var r = RTMPChunkReader()
        r.chunkSize = 16
        let m = RTMPMessage(
            chunkStreamID: 6, typeID: 9, messageStreamID: 1, timestamp: 0x0100_0000,
            payload: Array(repeating: 7, count: 100))
        let next = RTMPMessage(
            chunkStreamID: 6, typeID: 9, messageStreamID: 1, timestamp: 0x0100_0021,
            payload: Array(repeating: 8, count: 40))
        #expect(try r.push(w.encode(m) + w.encode(next)) == [m, next])
    }

    @Test func extendedTimestampRepeatsOnContinuations() {
        var w = RTMPChunkWriter()
        w.chunkSize = 1
        let out = w.encode(RTMPMessage(chunkStreamID: 6, typeID: 9, messageStreamID: 1, timestamp: 0x0100_0000, payload: [1, 2]))
        // Type 0 header with 0xFFFFFF, its extended timestamp, one byte; then a type 3 that repeats it.
        #expect(Array(out.suffix(6)) == [0xC6, 0x01, 0x00, 0x00, 0x00, 2])
    }

    @Test func deltaHeaderRoundTrips() throws {
        var w = RTMPChunkWriter()
        var r = RTMPChunkReader()
        let first = message(csid: 4, type: 8, stream: 1, time: 10, size: 4)
        let sameShape = message(csid: 4, type: 8, stream: 1, time: 31, size: 4, fill: 2)
        let newShape = message(csid: 4, type: 8, stream: 1, time: 52, size: 9, fill: 3)
        let a = w.encode(first)
        let b = w.encode(sameShape)
        let c = w.encode(newShape)
        #expect(b.first == 0x84)  // type 2: only the delta
        #expect(c.first == 0x44)  // type 1: delta, length and type
        #expect(try r.push(a + b + c) == [first, sameShape, newShape])
    }

    @Test func backwardTimestampUsesAbsoluteHeader() throws {
        var w = RTMPChunkWriter()
        var r = RTMPChunkReader()
        let first = message(csid: 6, type: 9, stream: 1, time: 100, size: 4)
        let back = message(csid: 6, type: 9, stream: 1, time: 90, size: 4, fill: 5)
        let wire = w.encode(first) + w.encode(back)
        #expect(try r.push(wire) == [first, back])
    }

    @Test func readerHandlesTwoAndThreeByteChunkStreamIDs() throws {
        var w = RTMPChunkWriter()
        var r = RTMPChunkReader()
        let two = message(csid: 64, type: 8, stream: 1, time: 0, size: 3)
        let three = message(csid: 320, type: 9, stream: 1, time: 0, size: 3)
        let a = w.encode(two)
        let b = w.encode(three)
        #expect(Array(a.prefix(2)) == [0x00, 0x00])
        #expect(Array(b.prefix(3)) == [0x01, 0x00, 0x01])
        #expect(try r.push(a + b) == [two, three])
    }

    @Test func readerAcceptsOneByteAtATime() throws {
        var w = RTMPChunkWriter()
        var r = RTMPChunkReader()
        let m = message(csid: 6, type: 9, stream: 1, time: 0x0100_0000, size: 500)
        var out: [RTMPMessage] = []
        for byte in w.encode(m) { out += try r.push([byte]) }
        #expect(out == [m])
    }

    @Test func setChunkSizeAppliesToTheFollowingChunks() throws {
        // A Set Chunk Size message raises the size for the rest of the same push.
        var w = RTMPChunkWriter()
        let setSize = RTMPMessage(chunkStreamID: 2, typeID: 1, messageStreamID: 0, timestamp: 0, payload: [0, 0, 0x10, 0])
        let wire = w.encode(setSize)
        w.chunkSize = 4096
        let big = message(csid: 3, type: 20, stream: 0, time: 0, size: 1000)
        var r = RTMPChunkReader()
        #expect(try r.push(wire + w.encode(big)) == [setSize, big])
        #expect(r.chunkSize == 4096)
    }

    @Test func invalidSetChunkSizeThrows() {
        var r = RTMPChunkReader()
        #expect(throws: RTMPChunkError.invalidChunkSize) {
            try r.push([0x02, 0, 0, 0, 0, 0, 4, 1, 0, 0, 0, 0, 0, 0, 0, 0])
        }
    }

    @Test func oversizedMessageIsRejected() {
        var r = RTMPChunkReader(maxMessageBytes: 1024)
        #expect(throws: RTMPChunkError.messageTooLarge) {
            try r.push([0x03, 0, 0, 0, 0xFF, 0xFF, 0xFF, 8, 0, 0, 0, 0])
        }
    }

    @Test func manyPartialMessagesStayWithinTheBound() {
        // Partial messages on many chunk streams may not add up past the bound either.
        var r = RTMPChunkReader(maxMessageBytes: 1024)
        var wire: [UInt8] = []
        for csid in 3..<40 { wire += [UInt8(csid), 0, 0, 0, 0, 0x03, 0xFF, 8, 0, 0, 0, 0] + Array(repeating: 0, count: 128) }
        #expect(throws: RTMPChunkError.messageTooLarge) { try r.push(wire) }
    }

    @Test func type3WithoutPriorHeaderThrows() {
        var r = RTMPChunkReader()
        #expect(throws: RTMPChunkError.missingPriorHeader) { try r.push([0xC3, 1]) }
    }
}
