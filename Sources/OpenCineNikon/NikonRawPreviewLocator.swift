import Foundation

/// The byte range of one JPEG image embedded in a TIFF-structured RAW file (NEF, NRW).
public struct NikonEmbeddedPreviewRange: Equatable, Sendable {
    /// Byte offset of the JPEG's start-of-image marker from the start of the RAW file.
    public let offset: UInt32
    /// JPEG length in bytes.
    public let length: UInt32
    /// The RAW's EXIF orientation (IFD0 tag `0x0112`, 1 to 8), when recorded. The embedded
    /// JPEG usually carries no EXIF of its own, so a portrait shot would decode sideways
    /// without it; see ``NikonRawPreviewLocator/taggingOrientation(_:orientation:)``.
    public let orientation: UInt16?

    /// Creates a range.
    public init(offset: UInt32, length: UInt32, orientation: UInt16? = nil) {
        self.offset = offset
        self.length = length
        self.orientation = orientation
    }
}

/// Finds the largest JPEG preview embedded in the head of a NEF or NRW file.
///
/// A Nikon RAW is a TIFF container: IFD0 (and any chained IFDs) plus the SubIFDs it lists
/// (tag `0x014A`). The camera stores its previews there, either as an old-style JPEG
/// (`JPEGInterchangeFormat` `0x0201` with `JPEGInterchangeFormatLength` `0x0202`) or as a
/// single-strip image whose `Compression` (`0x0103`) is JPEG (6 or 7). The sensor data
/// itself also lives in a SubIFD; it is skipped by its CFA or linear-raw photometric
/// interpretation and its more-than-8-bit samples.
///
/// Reading the whole RAW over Wi-Fi would take seconds, so the review reads only the head
/// (``defaultHeadLength``), locates the preview here, and then reads just that range. The
/// locator is pure: it inspects bytes and never performs I/O. An IFD that lies past the head
/// is skipped rather than guessed. Returns nil when the head is not a TIFF or names no
/// usable JPEG; the caller then keeps the camera's own thumbnail.
///
/// [verify-on-HW: which IFD holds the largest preview on each Z body, and its size]
public enum NikonRawPreviewLocator {
    /// Bytes read from the start of a RAW file to find its IFDs. Nikon writes IFD0 and its
    /// SubIFD directories near the start; 256 KB also covers the uncompressed IFD0 thumbnail
    /// strip that sits between them on some bodies.
    public static let defaultHeadLength: UInt32 = 256 * 1024

    /// The largest preview the review accepts; larger embedded images are ignored so one
    /// review cannot hold the shared camera channel for a whole-file transfer.
    public static let maximumPreviewLength: UInt32 = 16 * 1024 * 1024

    /// The largest usable embedded JPEG in `head`.
    ///
    /// - Parameters:
    ///   - head: The first bytes of the RAW file (all of it is fine too).
    ///   - objectSize: The RAW file's size, when known; previews that would end past it are
    ///     rejected as corrupt.
    public static func largestPreview(
        inHead head: [UInt8], objectSize: UInt32? = nil
    ) -> NikonEmbeddedPreviewRange? {
        guard let reader = TIFFReader(head) else { return nil }
        let directories = reader.directories()
        var best: NikonEmbeddedPreviewRange?
        for directory in directories {
            guard let candidate = directory.jpegRange,
                isUsable(candidate, head: head, objectSize: objectSize)
            else { continue }
            if best.map({ candidate.length > $0.length }) ?? true {
                best = candidate
            }
        }
        guard let best else { return nil }
        let orientation = directories.first?.orientation.flatMap { (1...8).contains($0) ? $0 : nil }
        return NikonEmbeddedPreviewRange(
            offset: best.offset, length: best.length, orientation: orientation.map { UInt16($0) })
    }

    /// `jpeg` with an EXIF orientation segment, so decoders that honor EXIF (ImageIO,
    /// Android's `ExifInterface`) show the preview upright. Unchanged when the orientation is
    /// upright or unknown, when `jpeg` is not a JPEG, or when it already has an EXIF segment.
    public static func taggingOrientation(_ jpeg: Data, orientation: UInt16?) -> Data {
        guard let orientation, (2...8).contains(orientation) else { return jpeg }
        let bytes = [UInt8](jpeg)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8, !hasExifSegment(bytes)
        else { return jpeg }
        // APP1 "Exif\0\0" + a big-endian TIFF with one IFD holding Orientation (SHORT).
        var segment: [UInt8] = [0xFF, 0xE1, 0x00, 0x22]
        segment += [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
        segment += [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]
        segment += [0x00, 0x01]
        segment += [0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01]
        segment += [UInt8(orientation >> 8), UInt8(orientation & 0xFF), 0x00, 0x00]
        segment += [0x00, 0x00, 0x00, 0x00]
        var tagged: [UInt8] = []
        tagged.reserveCapacity(bytes.count + segment.count)
        tagged += bytes[0..<2]
        tagged += segment
        tagged += bytes[2...]
        return Data(tagged)
    }

    /// Whether an APP1 `Exif` segment appears before the image data starts.
    private static func hasExifSegment(_ bytes: [UInt8]) -> Bool {
        var offset = 2
        while offset + 4 <= bytes.count, bytes[offset] == 0xFF {
            let marker = bytes[offset + 1]
            // Start of scan: no metadata segment can follow.
            if marker == 0xDA { return false }
            let length = Int(ByteCoding.readUInt16BE(bytes, at: offset + 2))
            if marker == 0xE1, offset + 8 <= bytes.count,
                bytes[(offset + 4)..<(offset + 8)].elementsEqual([0x45, 0x78, 0x69, 0x66])
            {
                return true
            }
            guard length >= 2 else { return false }
            offset += 2 + length
        }
        return false
    }

    private static func isUsable(
        _ range: NikonEmbeddedPreviewRange, head: [UInt8], objectSize: UInt32?
    ) -> Bool {
        guard range.offset > 0, range.length >= 4, range.length <= maximumPreviewLength
        else { return false }
        let end = UInt64(range.offset) + UInt64(range.length)
        if let objectSize, end > UInt64(objectSize) { return false }
        // When the preview starts inside the head, it must open with a JPEG SOI marker.
        let start = Int(range.offset)
        if start + 1 < head.count, head[start] != 0xFF || head[start + 1] != 0xD8 {
            return false
        }
        return true
    }
}

/// The fields of one TIFF image file directory that matter for locating a JPEG.
private struct TIFFDirectory {
    var jpegOffset: UInt32?
    var jpegLength: UInt32?
    var compression: UInt32?
    var photometric: UInt32?
    var bitsPerSample: UInt32?
    var stripOffset: UInt32?
    var stripLength: UInt32?
    var orientation: UInt32?

    /// CFA (32803) and LinearRaw (34892) hold sensor data, never a viewable preview.
    private static let sensorPhotometrics: Set<UInt32> = [32803, 34892]

    var jpegRange: NikonEmbeddedPreviewRange? {
        if let jpegOffset, let jpegLength {
            return NikonEmbeddedPreviewRange(offset: jpegOffset, length: jpegLength)
        }
        guard let compression, compression == 6 || compression == 7,
            let stripOffset, let stripLength,
            !Self.sensorPhotometrics.contains(photometric ?? 0),
            (bitsPerSample ?? 8) <= 8
        else { return nil }
        return NikonEmbeddedPreviewRange(offset: stripOffset, length: stripLength)
    }
}

/// A bounds-checked TIFF walker over a byte prefix.
private struct TIFFReader {
    private let bytes: [UInt8]
    private let littleEndian: Bool
    /// Set once the header is read; the header readers need `self` first.
    private var firstDirectory: UInt32 = 0

    /// Directories visited at most; a corrupt chain cannot loop forever.
    private static let maximumDirectories = 32
    /// Entries read per directory at most.
    private static let maximumEntries = 1_024
    /// SubIFD offsets followed per directory at most.
    private static let maximumSubDirectories = 8

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 8 else { return nil }
        switch (bytes[0], bytes[1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: return nil
        }
        self.bytes = bytes
        guard uint16(at: 2) == 42, let first = uint32(at: 4) else { return nil }
        firstDirectory = first
    }

    /// Every reachable directory: the IFD chain from IFD0 plus each SubIFD, breadth first.
    func directories() -> [TIFFDirectory] {
        var pending: [UInt32] = [firstDirectory]
        var visited: Set<UInt32> = []
        var result: [TIFFDirectory] = []
        while !pending.isEmpty, visited.count < Self.maximumDirectories {
            let offset = pending.removeFirst()
            guard offset >= 8, visited.insert(offset).inserted,
                let parsed = directory(at: Int(offset))
            else { continue }
            result.append(parsed.directory)
            pending.append(contentsOf: parsed.children)
        }
        return result
    }

    private func directory(at offset: Int) -> (directory: TIFFDirectory, children: [UInt32])? {
        guard let count = uint16(at: offset), count > 0,
            Int(count) <= Self.maximumEntries,
            offset + 2 + Int(count) * 12 <= bytes.count
        else { return nil }
        var directory = TIFFDirectory()
        var children: [UInt32] = []
        for index in 0..<Int(count) {
            let entry = offset + 2 + index * 12
            guard let tag = uint16(at: entry), let type = uint16(at: entry + 2),
                let valueCount = uint32(at: entry + 4)
            else { continue }
            let field = entry + 8
            switch tag {
            case 0x0102: directory.bitsPerSample = firstValue(type, valueCount, field)
            case 0x0103: directory.compression = scalar(type, valueCount, field)
            case 0x0106: directory.photometric = scalar(type, valueCount, field)
            case 0x0111: directory.stripOffset = scalar(type, valueCount, field)
            case 0x0112: directory.orientation = scalar(type, valueCount, field)
            case 0x0117: directory.stripLength = scalar(type, valueCount, field)
            case 0x0201: directory.jpegOffset = scalar(type, valueCount, field)
            case 0x0202: directory.jpegLength = scalar(type, valueCount, field)
            case 0x014A: children += offsets(type, valueCount, field)
            default: break
            }
        }
        if let next = uint32(at: offset + 2 + Int(count) * 12), next != 0 {
            children.append(next)
        }
        return (directory, children)
    }

    /// A single SHORT or LONG value stored inline; nil for arrays (multi-strip images are
    /// never a single JPEG) and other types.
    private func scalar(_ type: UInt16, _ count: UInt32, _ field: Int) -> UInt32? {
        guard count == 1 else { return nil }
        return firstValue(type, count, field)
    }

    /// The first SHORT or LONG of a value, inline or out of line.
    private func firstValue(_ type: UInt16, _ count: UInt32, _ field: Int) -> UInt32? {
        guard count >= 1 else { return nil }
        switch type {
        case 3:
            if count <= 2 { return uint16(at: field).map(UInt32.init) }
            return uint32(at: field).flatMap { uint16(at: Int($0)) }.map(UInt32.init)
        case 4, 13:
            if count == 1 { return uint32(at: field) }
            return uint32(at: field).flatMap { uint32(at: Int($0)) }
        default:
            return nil
        }
    }

    /// The directory offsets of a SubIFDs entry (LONG or IFD type).
    private func offsets(_ type: UInt16, _ count: UInt32, _ field: Int) -> [UInt32] {
        guard type == 4 || type == 13, count >= 1 else { return [] }
        let limited = min(Int(count), Self.maximumSubDirectories)
        if count == 1 { return uint32(at: field).map { [$0] } ?? [] }
        guard let base = uint32(at: field) else { return [] }
        return (0..<limited).compactMap { uint32(at: Int(base) + $0 * 4) }
    }

    private func uint16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return littleEndian
            ? ByteCoding.readUInt16LE(bytes, at: offset)
            : ByteCoding.readUInt16BE(bytes, at: offset)
    }

    private func uint32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return littleEndian
            ? ByteCoding.readUInt32LE(bytes, at: offset)
            : ByteCoding.readUInt32BE(bytes, at: offset)
    }
}
