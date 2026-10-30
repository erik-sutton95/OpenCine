import Foundation

/// Makes the camera's thumbnail of a still show the way the photographer framed it.
///
/// `GetThumb` (0x100A) serves the still's small embedded thumbnail: a bare JPEG of the stored
/// sensor pixels with no EXIF (a NIKON ZR NEF's 160 x 120 IFD0 thumbnail has only DQT, DHT,
/// SOF0 and SOS). Only the still itself records how the body was held, in IFD0 tag `0x0112`
/// near its start, so a portrait shot's thumbnail would draw sideways. The reader takes that
/// tag from one small read of the still's head (``headLength``, never the whole file) and
/// writes it into the thumbnail as an EXIF segment. Every decoder that honors EXIF (ImageIO
/// with the thumbnail transform on iOS, the shared bitmap decoder on Android) then draws the
/// thumbnail upright, and the cached thumbnail file keeps the fact.
///
/// The I/O stays with the caller's session through `readThumbnail` and `readHead(length)`, so
/// the same rule runs on the iOS async session and the Android blocking session.
public enum NikonThumbnailOrientation {
    /// Bytes read from the start of a still to find its orientation. A JPEG's EXIF IFD0 and a
    /// NEF's IFD0 both start at TIFF offset 8; on a ZR NEF the tag sits in the first 80 bytes.
    public static let headLength: UInt32 = 8 * 1024

    /// Blocking variant (Android facade). Nil when the camera serves no thumbnail; the
    /// camera's thumbnail unchanged when the still's orientation cannot be read.
    public static func uprightThumbnail(
        filename: String, readThumbnail: () throws -> Data?, readHead: (UInt32) throws -> Data
    ) throws -> Data? {
        guard let thumbnail = try readThumbnail() else { return nil }
        guard needsOrientation(thumbnail, filename: filename),
            let head = try? readHead(headLength)
        else { return thumbnail }
        return tagging(thumbnail, head: head)
    }

    /// Async variant (iOS session).
    public static func uprightThumbnail(
        filename: String, readThumbnail: () async throws -> Data?,
        readHead: (UInt32) async throws -> Data
    ) async throws -> Data? {
        guard let thumbnail = try await readThumbnail() else { return nil }
        guard needsOrientation(thumbnail, filename: filename),
            let head = try? await readHead(headLength)
        else { return thumbnail }
        return tagging(thumbnail, head: head)
    }

    /// The EXIF orientation (1 to 8) a JPEG's APP1 `Exif` segment or a TIFF-structured file
    /// (NEF, NRW, TIFF) records in IFD0; nil when `head` names none.
    static func orientation(inHead head: [UInt8]) -> UInt16? {
        let tiff: [UInt8]
        if head.count >= 2, head[0] == 0xFF, head[1] == 0xD8 {
            guard let range = JPEGSegments(head).exifTIFF else { return nil }
            tiff = Array(head[range])
        } else {
            tiff = head
        }
        guard let value = TIFFReader(tiff)?.directories().first?.orientation,
            (1...8).contains(value)
        else { return nil }
        return UInt16(value)
    }

    /// `jpeg` carrying only `orientation` as its EXIF, so EXIF-honoring decoders draw it
    /// upright. Any EXIF segment without the tag is replaced; `jpeg` is unchanged when it is
    /// not a JPEG.
    static func taggingOrientation(_ jpeg: Data, orientation: UInt16) -> Data {
        let bytes = [UInt8](jpeg)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return jpeg }
        let layout = JPEGSegments(bytes)
        var tagged: [UInt8] = [0xFF, 0xD8] + exifSegment(orientation: orientation)
        tagged.reserveCapacity(bytes.count + 36)
        for segment in layout.segments where !segment.isExif {
            tagged += bytes[segment.range]
        }
        tagged += bytes[layout.imageDataStart...]
        return Data(tagged)
    }

    /// APP1 `Exif\0\0` holding a big-endian TIFF with one IFD whose only entry is
    /// Orientation (SHORT).
    static func exifSegment(orientation: UInt16) -> [UInt8] {
        var segment: [UInt8] = [0xFF, 0xE1, 0x00, 0x22]
        segment += [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
        segment += [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]
        segment += [0x00, 0x01]
        segment += [0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01]
        segment += [UInt8(orientation >> 8), UInt8(orientation & 0xFF), 0x00, 0x00]
        segment += [0x00, 0x00, 0x00, 0x00]
        return segment
    }

    /// A still's thumbnail that does not state an orientation of its own. Clips and HEIF
    /// stills keep the camera's thumbnail: their heads carry no EXIF IFD0 to read.
    private static func needsOrientation(_ thumbnail: Data, filename: String) -> Bool {
        switch (filename as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "nef", "nrw", "tif", "tiff":
            return orientation(inHead: [UInt8](thumbnail)) == nil
        default:
            return false
        }
    }

    private static func tagging(_ thumbnail: Data, head: Data) -> Data {
        guard let orientation = orientation(inHead: [UInt8](head)), orientation != 1 else {
            return thumbnail
        }
        return taggingOrientation(thumbnail, orientation: orientation)
    }
}

/// The metadata segments of a JPEG, from SOI up to the first start of scan.
private struct JPEGSegments {
    struct Segment {
        let range: Range<Int>
        let isExif: Bool
    }

    private(set) var segments: [Segment] = []
    /// Where the first segment past the walk starts (SOS, or where the walk stopped).
    private(set) var imageDataStart = 2

    init(_ bytes: [UInt8]) {
        var offset = 2
        while offset + 4 <= bytes.count, bytes[offset] == 0xFF {
            let marker = bytes[offset + 1]
            // Start of scan or end of image: no metadata segment follows.
            if marker == 0xDA || marker == 0xD9 { break }
            let length = Int(ByteCoding.readUInt16BE(bytes, at: offset + 2))
            guard length >= 2 else { break }
            let end = min(offset + 2 + length, bytes.count)
            let isExif =
                marker == 0xE1 && offset + 10 <= bytes.count
                && bytes[(offset + 4)..<(offset + 10)].elementsEqual([
                    0x45, 0x78, 0x69, 0x66, 0x00, 0x00,
                ])
            segments.append(Segment(range: offset..<end, isExif: isExif))
            offset = end
        }
        imageDataStart = min(offset, bytes.count)
    }

    /// The TIFF structure inside the first APP1 `Exif` segment (possibly cut short by the head).
    var exifTIFF: Range<Int>? {
        segments.first(where: \.isExif).map { ($0.range.lowerBound + 10)..<$0.range.upperBound }
    }
}
