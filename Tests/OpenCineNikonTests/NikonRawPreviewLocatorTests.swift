import Foundation
import Testing

@testable import OpenCineNikon

/// Builds small TIFF/NEF byte layouts in-test: IFDs are written in order after the 8-byte
/// header, out-of-line SubIFD arrays after the IFDs, then the file is zero-padded to `size`
/// and `patches` are copied in (JPEG payloads, corrupt bytes).
enum NEFFixture {
    enum Value {
        case short(UInt16)
        case long(UInt32)
        /// A pointer to another directory by its index in the directory list.
        case directory(Int)
        /// A SubIFDs array of directory indexes (inline for one, out of line for more).
        case directories([Int])
    }

    struct Entry {
        let tag: UInt16
        let value: Value
    }

    struct Directory {
        var entries: [Entry]
        /// The next directory in the IFD chain, by index.
        var next: Int? = nil
    }

    static func build(
        _ directories: [Directory], littleEndian: Bool = true, size: Int,
        patches: [(offset: Int, bytes: [UInt8])] = []
    ) -> [UInt8] {
        func u16(_ value: UInt16) -> [UInt8] {
            littleEndian ? ByteCoding.uint16LE(value) : ByteCoding.uint16BE(value)
        }
        func u32(_ value: UInt32) -> [UInt8] {
            littleEndian ? ByteCoding.uint32LE(value) : ByteCoding.uint32BE(value)
        }
        var offsets: [UInt32] = []
        var cursor = 8
        for directory in directories {
            offsets.append(UInt32(cursor))
            cursor += 2 + directory.entries.count * 12 + 4
        }
        var arrays: [UInt8] = []
        var bytes: [UInt8] = littleEndian ? [0x49, 0x49] : [0x4D, 0x4D]
        bytes += u16(42) + u32(8)
        for directory in directories {
            bytes += u16(UInt16(directory.entries.count))
            for entry in directory.entries {
                bytes += u16(entry.tag)
                switch entry.value {
                case .short(let value):
                    bytes += u16(3) + u32(1) + u16(value) + [0, 0]
                case .long(let value):
                    bytes += u16(4) + u32(1) + u32(value)
                case .directory(let index):
                    bytes += u16(13) + u32(1) + u32(offsets[index])
                case .directories(let indexes) where indexes.count == 1:
                    bytes += u16(4) + u32(1) + u32(offsets[indexes[0]])
                case .directories(let indexes):
                    let arrayOffset = UInt32(cursor + arrays.count)
                    bytes += u16(4) + u32(UInt32(indexes.count)) + u32(arrayOffset)
                    for index in indexes { arrays += u32(offsets[index]) }
                }
            }
            bytes += u32(directory.next.map { offsets[$0] } ?? 0)
        }
        bytes += arrays
        if bytes.count < size { bytes += [UInt8](repeating: 0, count: size - bytes.count) }
        for patch in patches {
            let end = patch.offset + patch.bytes.count
            bytes.replaceSubrange(patch.offset..<end, with: patch.bytes)
        }
        return bytes
    }

    /// A tiny JPEG-shaped payload: SOI, filler, EOI.
    static func jpeg(length: Int, fill: UInt8 = 0x11) -> [UInt8] {
        [0xFF, 0xD8] + [UInt8](repeating: fill, count: max(0, length - 4)) + [0xFF, 0xD9]
    }

    /// A Z-style NEF: IFD0 (uncompressed RGB thumbnail strip, orientation, two SubIFDs, a
    /// chained IFD1), SubIFD 1 = the large JPEG preview past the 256 KB head, SubIFD 2 = the
    /// sensor data, IFD1 = a smaller JPEG.
    static func zStyleNEF(
        littleEndian: Bool = true, orientation: UInt16 = 1,
        previewOffset: Int = 300_000, previewLength: Int = 4_000
    ) -> (bytes: [UInt8], preview: [UInt8]) {
        let preview = jpeg(length: previewLength, fill: 0x5A)
        let small = jpeg(length: 900, fill: 0x33)
        let ifd0 = Directory(
            entries: [
                Entry(tag: 0x0100, value: .long(160)),
                Entry(tag: 0x0101, value: .long(120)),
                Entry(tag: 0x0103, value: .short(1)),
                Entry(tag: 0x0106, value: .short(2)),
                Entry(tag: 0x0111, value: .long(4_096)),
                Entry(tag: 0x0112, value: .short(orientation)),
                Entry(tag: 0x0117, value: .long(57_600)),
                Entry(tag: 0x014A, value: .directories([1, 2])),
            ],
            next: 3)
        let previewIFD = Directory(entries: [
            Entry(tag: 0x0103, value: .short(6)),
            Entry(tag: 0x0201, value: .long(UInt32(previewOffset))),
            Entry(tag: 0x0202, value: .long(UInt32(previewLength))),
        ])
        let sensorIFD = Directory(entries: [
            Entry(tag: 0x0102, value: .short(14)),
            Entry(tag: 0x0103, value: .short(34_713)),
            Entry(tag: 0x0106, value: .short(32_803)),
            Entry(tag: 0x0111, value: .long(400_000)),
            Entry(tag: 0x0117, value: .long(9_000_000)),
        ])
        let ifd1 = Directory(entries: [
            Entry(tag: 0x0103, value: .short(6)),
            Entry(tag: 0x0201, value: .long(70_000)),
            Entry(tag: 0x0202, value: .long(900)),
        ])
        let bytes = build(
            [ifd0, previewIFD, sensorIFD, ifd1], littleEndian: littleEndian,
            size: previewOffset + previewLength,
            patches: [(70_000, small), (previewOffset, preview)])
        return (bytes, preview)
    }
}

@Suite("NEF embedded preview locator")
struct NikonRawPreviewLocatorTests {
    private let head = Int(NikonRawPreviewLocator.defaultHeadLength)

    @Test func findsTheLargestJPEGAcrossSubIFDsAndTheIFDChain() throws {
        let nef = NEFFixture.zStyleNEF(orientation: 6)
        let range = try #require(
            NikonRawPreviewLocator.largestPreview(
                inHead: Array(nef.bytes.prefix(head)), objectSize: UInt32(nef.bytes.count)))
        #expect(range.offset == 300_000)
        #expect(range.length == 4_000)
        #expect(range.orientation == 6)
        let start = Int(range.offset)
        #expect(Array(nef.bytes[start..<(start + Int(range.length))]) == nef.preview)
    }

    @Test func readsBigEndianNEFsToo() throws {
        let nef = NEFFixture.zStyleNEF(littleEndian: false, orientation: 8)
        let range = try #require(
            NikonRawPreviewLocator.largestPreview(inHead: Array(nef.bytes.prefix(head))))
        #expect(range == NikonEmbeddedPreviewRange(offset: 300_000, length: 4_000, orientation: 8))
    }

    @Test func acceptsASingleStripJPEGButNeverTheSensorData() throws {
        // Lossless-JPEG sensor data (compression 7, CFA, 14 bit) is larger than the preview strip
        // and must still lose to it.
        let preview = NEFFixture.jpeg(length: 2_000)
        let ifd0 = NEFFixture.Directory(entries: [
            .init(tag: 0x014A, value: .directories([1, 2]))
        ])
        let sensor = NEFFixture.Directory(entries: [
            .init(tag: 0x0102, value: .short(14)),
            .init(tag: 0x0103, value: .short(7)),
            .init(tag: 0x0106, value: .short(32_803)),
            .init(tag: 0x0111, value: .long(10_000)),
            .init(tag: 0x0117, value: .long(80_000)),
        ])
        let strip = NEFFixture.Directory(entries: [
            .init(tag: 0x0102, value: .short(8)),
            .init(tag: 0x0103, value: .short(7)),
            .init(tag: 0x0106, value: .short(6)),
            .init(tag: 0x0111, value: .long(5_000)),
            .init(tag: 0x0117, value: .long(2_000)),
        ])
        let bytes = NEFFixture.build(
            [ifd0, sensor, strip], size: 90_000, patches: [(5_000, preview)])
        let range = try #require(NikonRawPreviewLocator.largestPreview(inHead: bytes))
        #expect(range.offset == 5_000)
        #expect(range.length == 2_000)
        #expect(range.orientation == nil)
    }

    @Test func rejectsPreviewsThatAreNotJPEGOrRunPastTheFile() {
        let nef = NEFFixture.zStyleNEF()
        // The preview would end past the object: corrupt, so only IFD1's small JPEG is left.
        let short = NikonRawPreviewLocator.largestPreview(
            inHead: Array(nef.bytes.prefix(head)), objectSize: 200_000)
        #expect(short?.offset == 70_000)
        // A range inside the head that does not open with SOI is not a JPEG.
        var corrupt = nef.bytes
        corrupt[70_000] = 0x00
        let inHead = NikonRawPreviewLocator.largestPreview(
            inHead: Array(corrupt.prefix(head)), objectSize: 200_000)
        #expect(inHead == nil)
    }

    @Test func returnsNilForNonTIFFTruncatedOrLoopingInput() {
        #expect(NikonRawPreviewLocator.largestPreview(inHead: NEFFixture.jpeg(length: 64)) == nil)
        #expect(NikonRawPreviewLocator.largestPreview(inHead: [0x49, 0x49, 0x2A]) == nil)
        // IFD0 lies past the bytes we have.
        let nef = NEFFixture.zStyleNEF()
        #expect(NikonRawPreviewLocator.largestPreview(inHead: Array(nef.bytes.prefix(40))) == nil)
        // A chain that points back at itself terminates.
        let looping = NEFFixture.build(
            [NEFFixture.Directory(entries: [.init(tag: 0x0103, value: .short(6))], next: 0)],
            size: 64)
        #expect(NikonRawPreviewLocator.largestPreview(inHead: looping) == nil)
    }

    @Test func tagsThePreviewWithTheRAWOrientation() {
        let jpeg = Data(NEFFixture.jpeg(length: 32))
        let tagged = [UInt8](NikonRawPreviewLocator.taggingOrientation(jpeg, orientation: 6))
        #expect(tagged.count == jpeg.count + 36)
        #expect(Array(tagged[0..<4]) == [0xFF, 0xD8, 0xFF, 0xE1])
        #expect(Array(tagged[6..<12]) == [0x45, 0x78, 0x69, 0x66, 0x00, 0x00])
        // Big-endian TIFF: one IFD at 8 whose only entry is Orientation (0x0112, SHORT) = 6.
        #expect(Array(tagged[12..<16]) == [0x4D, 0x4D, 0x00, 0x2A])
        #expect(Array(tagged[22..<24]) == [0x01, 0x12])
        #expect(Array(tagged[30..<32]) == [0x00, 0x06])
        #expect(Array(tagged[38...]) == Array(jpeg[2...]))
    }

    @Test func leavesUprightOrAlreadyTaggedJPEGsAlone() {
        let jpeg = Data(NEFFixture.jpeg(length: 32))
        #expect(NikonRawPreviewLocator.taggingOrientation(jpeg, orientation: 1) == jpeg)
        #expect(NikonRawPreviewLocator.taggingOrientation(jpeg, orientation: nil) == jpeg)
        let tagged = NikonRawPreviewLocator.taggingOrientation(jpeg, orientation: 3)
        #expect(NikonRawPreviewLocator.taggingOrientation(tagged, orientation: 6) == tagged)
        let notJPEG = Data([0x00, 0x01, 0x02, 0x03])
        #expect(NikonRawPreviewLocator.taggingOrientation(notJPEG, orientation: 6) == notJPEG)
    }
}
