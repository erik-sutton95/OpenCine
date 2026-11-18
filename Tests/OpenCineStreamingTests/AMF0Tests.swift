import Foundation
import Testing

@testable import OpenCineStreaming

@Suite struct AMF0Tests {
    @Test func encodesCommandExactly() {
        #expect(
            AMF0.encode([.string("connect"), .number(1), .null])
                == [0x02, 0x00, 0x07] + Array("connect".utf8)
                + [0x00, 0x3F, 0xF0, 0, 0, 0, 0, 0, 0] + [0x05])
    }

    @Test func objectEndsWithEndMarker() {
        #expect(
            AMF0.encode([.object([AMF0Property(name: "a", value: .boolean(true))])])
                == [0x03, 0x00, 0x01, 0x61, 0x01, 0x01, 0x00, 0x00, 0x09])
    }

    @Test func stringOver65535UsesLongMarker() throws {
        let long = String(repeating: "x", count: 70_000)
        let bytes = AMF0.encode([.string(long)])
        #expect(bytes.first == 0x0C)
        #expect(try AMF0.decode(bytes) == [.string(long)])
    }

    @Test func decodeRoundTripsEveryValue() throws {
        let values: [AMF0Value] = [
            .number(-12.5), .boolean(false), .boolean(true), .string("héllo"),
            .object([
                AMF0Property(name: "code", value: .string("NetStream.Publish.Start")),
                AMF0Property(name: "nested", value: .object([AMF0Property(name: "n", value: .number(3))])),
            ]),
            .ecmaArray([AMF0Property(name: "width", value: .number(1280))]),
            .null, .undefined,
        ]
        #expect(try AMF0.decode(AMF0.encode(values)) == values)
    }

    @Test(arguments: [[UInt8]([0x02, 0x00, 0x09, 0x61]), [0x00, 0x3F], [0x03, 0x00, 0x01], [0x08, 0, 0]])
    func truncatedInputThrows(bytes: [UInt8]) {
        #expect(throws: AMF0Error.truncated) { try AMF0.decode(bytes) }
    }

    @Test func unknownMarkerThrows() {
        #expect(throws: AMF0Error.unsupportedMarker(0x7F)) { try AMF0.decode([0x7F]) }
    }

    @Test func deepNestingThrows() {
        var bytes: [UInt8] = []
        for _ in 0..<1000 { bytes += [0x03, 0x00, 0x01, 0x61] }
        #expect(throws: AMF0Error.nestedTooDeep) { try AMF0.decode(bytes) }
    }

    @Test func hugeDeclaredArrayCountDoesNotAllocate() throws {
        // An ECMA array declaring four billion entries but holding none decodes as empty.
        #expect(try AMF0.decode([0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x09]) == [.ecmaArray([])])
    }
}
