import Foundation
import OpenCineCore

// DJI wire members of the camera vocabulary (OpenCineCameraVocabulary) for this file.

/// Wire evidence for one store's answer to a `0x00/0x26` page query.
public struct MediaPageSliceInfo: Equatable, Sendable {
    public var declared: Int
    public var records: Int
    public var endMarker: Bool
    public var ended: Bool

    public init(declared: Int, records: Int, endMarker: Bool, ended: Bool) {
        self.declared = declared
        self.records = records
        self.endMarker = endMarker
        self.ended = ended
    }

    /// A plausible header promised more records than reached the decoder.
    public var incomplete: Bool {
        (1...MediaListCommand.countMax).contains(declared) && records < declared
    }
}

/// Result of advancing the independent SD and internal-storage page cursors.
public struct MediaPageStep: Equatable, Sendable {
    public var fresh: [MediaFile]
    public var sdCursor: UInt32
    public var internalCursor: UInt32
    public var moreAvailable: Bool

    public init(
        fresh: [MediaFile], sdCursor: UInt32, internalCursor: UInt32,
        moreAvailable: Bool
    ) {
        self.fresh = fresh
        self.sdCursor = sdCursor
        self.internalCursor = internalCursor
        self.moreAvailable = moreAvailable
    }
}

extension MediaListCommand {
    public static let pageSize = 45

    public static let countMax = 512

    public static let newestSD: UInt32 = 0x0000_0001

    public static let newestInternal: UInt32 = 0x4000_0001

    public static let sdCounter: UInt8 = 1

    public static let internalCounter: UInt8 = 2

    public static let listTemplate: [UInt8] = [
        0x4A, 0x00, 0x2A, 0x10,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
        0x2D, 0x00, 0x0D, 0x01, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
    ]

    public static let triggerPayload: [UInt8] = [
        0x4A, 0x04, 0x0E, 0x10,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
    ]

    public static func listPayload(counter: UInt8, cursor: UInt32) -> [UInt8] {
        var payload = listTemplate
        payload[4] = counter
        payload[10] = UInt8(cursor & 0xFF)
        payload[11] = UInt8((cursor >> 8) & 0xFF)
        payload[12] = UInt8((cursor >> 16) & 0xFF)
        payload[13] = UInt8((cursor >> 24) & 0xFF)
        return payload
    }

    public static func storeSlice(_ page: [MediaFile], store: Int) -> [MediaFile] {
        page.filter { self.store(of: $0) == store }
    }

    /// Oldest usable handle in one store, optionally strictly below its current cursor.
    public static func oldestHandle(
        _ page: [MediaFile], store: Int, below: UInt32? = nil
    ) -> UInt32? {
        storeSlice(page, store: store)
            .map(\.handle)
            .filter { handle in
                guard handle != 0 else { return false }
                return below.map { handle < $0 } ?? true
            }
            .min()
    }

    /// First page: replace each newest-page selector with that store's oldest returned handle.
    public static func seedPagination(
        page: [MediaFile], seen: inout Set<String>,
        slices: [Int: MediaPageSliceInfo] = [:]
    ) -> MediaPageStep {
        pageStep(
            sdCursor: newestSD, internalCursor: newestInternal, page: page, seen: &seen,
            slices: slices, initial: true)
    }

    /// Older page: advance each store only from handles in its own returned slice.
    public static func stepPagination(
        sdCursor: UInt32, internalCursor: UInt32, page: [MediaFile],
        seen: inout Set<String>, slices: [Int: MediaPageSliceInfo] = [:]
    ) -> MediaPageStep {
        pageStep(
            sdCursor: sdCursor, internalCursor: internalCursor, page: page, seen: &seen,
            slices: slices, initial: false)
    }

    /// A complete short page is final; a full page probably has an older page.
    public static func hasOlderPage(recordCount: Int, cursor: UInt32?) -> Bool {
        guard let cursor, cursor > 0 else { return false }
        return recordCount >= pageSize
    }

    /// Per-store end rule. Truncation outranks the final-page marker because missing chunks can sit
    /// before the record that carries that marker.
    public static func storeHasOlderPage(
        sliceSize: Int, cursorMoved: Bool, info: MediaPageSliceInfo?
    ) -> Bool {
        guard cursorMoved else { return false }
        guard let info else { return sliceSize >= pageSize }
        if info.incomplete { return true }
        if info.endMarker { return false }
        return sliceSize >= pageSize
    }

    private static func pageStep(
        sdCursor: UInt32, internalCursor: UInt32, page: [MediaFile],
        seen: inout Set<String>, slices: [Int: MediaPageSliceInfo], initial: Bool
    ) -> MediaPageStep {
        var fresh: [MediaFile] = []
        for file in page where seen.insert(pageKey(file)).inserted { fresh.append(file) }
        let sdOldest = oldestHandle(
            page, store: sdStorage, below: initial ? nil : sdCursor)
        let internalOldest = oldestHandle(
            page, store: internalStorage, below: initial ? nil : internalCursor)
        let more = !fresh.isEmpty
            && (storeHasOlderPage(
                sliceSize: storeSlice(page, store: sdStorage).count,
                cursorMoved: sdOldest != nil, info: slices[sdStorage])
                || storeHasOlderPage(
                    sliceSize: storeSlice(page, store: internalStorage).count,
                    cursorMoved: internalOldest != nil, info: slices[internalStorage]))
        return MediaPageStep(
            fresh: fresh, sdCursor: sdOldest ?? sdCursor,
            internalCursor: internalOldest ?? internalCursor, moreAvailable: more)
    }
}

/// Strip `0x00/0x27` 10-byte sub-headers and concat data chunks in arrival order.
public struct MediaChunkAssembler: Sendable {
    public private(set) var chunksByCounter: [UInt8: [UInt8]] = [:]
    public private(set) var chunkCountsByCounter: [UInt8: Int] = [:]
    public private(set) var startedCounters: Set<UInt8> = []
    public private(set) var dataCounters: Set<UInt8> = []
    public private(set) var endedCounters: Set<UInt8> = []
    public private(set) var chunkCount = 0
    public var sawEnd: Bool { !endedCounters.isEmpty }

    public init() {}

    public mutating func reset() {
        chunksByCounter = [:]
        chunkCountsByCounter = [:]
        startedCounters = []
        dataCounters = []
        endedCounters = []
        chunkCount = 0
    }

    /// Forget one store before its one-shot mount-race retry, retaining the other store's answer.
    public mutating func reset(counter: UInt8) {
        chunksByCounter[counter] = nil
        let removed = chunkCountsByCounter.removeValue(forKey: counter) ?? 0
        chunkCount = max(0, chunkCount - removed)
        startedCounters.remove(counter)
        dataCounters.remove(counter)
        endedCounters.remove(counter)
    }

    /// Accept a decoded DUML frame. Only `0x00/0x27` contributes.
    @discardableResult
    public mutating func ingest(_ frame: Duml.Frame) -> Bool {
        guard frame.cmdSet == 0x00, frame.cmdId == 0x27 else { return false }
        return ingestPayload(frame.payload)
    }

    @discardableResult
    public mutating func ingestPayload(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 10, payload[0] == 0x4A else { return false }
        let subtype = payload[1]
        let counter = payload[4]
        if subtype == 0x04 {
            startedCounters.insert(counter)
            return true
        }
        if subtype == 0x03 {
            endedCounters.insert(counter)
            return true
        }
        guard subtype == 0x01, payload.count > 10 else { return false }
        dataCounters.insert(counter)
        chunksByCounter[counter, default: []].append(contentsOf: payload.dropFirst(10))
        chunkCountsByCounter[counter, default: 0] += 1
        chunkCount += 1
        return true
    }

    public func assembled(counter: UInt8) -> [UInt8] {
        chunksByCounter[counter] ?? []
    }

    public func chunkCount(counter: UInt8) -> Int { chunkCountsByCounter[counter] ?? 0 }

    public func didEnd(counter: UInt8) -> Bool { endedCounters.contains(counter) }

    /// Start-without-data is the camera's empty-store closure; data streams need an explicit end.
    public func isClosed(counter: UInt8) -> Bool {
        endedCounters.contains(counter)
            || (startedCounters.contains(counter) && !dataCounters.contains(counter))
    }

    /// All requested answers closed and at least one carried data. Empty libraries use quiet fallback.
    public func streamsEnded(requiredCounters: [UInt8]) -> Bool {
        guard !dataCounters.isEmpty else { return false }
        let observed = startedCounters.union(dataCounters).union(endedCounters)
        return requiredCounters.allSatisfy { isClosed(counter: $0) }
            && observed.allSatisfy { isClosed(counter: $0) }
    }

    public func assembledMerged() -> [UInt8] {
        var out: [UInt8] = []
        for key in chunksByCounter.keys.sorted() {
            out.append(contentsOf: chunksByCounter[key] ?? [])
        }
        return out
    }

    public var isEmpty: Bool { chunkCount == 0 }
    public var hasResponse: Bool {
        !startedCounters.isEmpty || !dataCounters.isEmpty || !endedCounters.isEmpty
    }
}

/// CompositePack TLV decode. Port of Osmosis `CameraSession.decodeComposite`.
public enum MediaManifest {
    public static let videoExtensions: Set<String> = [
        "MP4", "MOV", "OSV", "INSV", "LRF", "LRV", "XRF",
    ]
    public static let photoExtensions: Set<String> = [
        "JPG", "JPEG", "DNG", "HEIC", "TIF", "TIFF", "PANO",
    ]

    public static func decode(_ bytes: [UInt8]) -> [MediaFile] {
        let records = decodeComposite(bytes)
        return flagHandleCollisions(withCmdHandles(records))
    }

    public static func decode(_ data: Data) -> [MediaFile] {
        decode([UInt8](data))
    }

    /// Split one collected blob into SD (ctr 1) and internal (ctr 2) when the camera echoed counters.
    public static func decodeStores(assembler: MediaChunkAssembler) -> [MediaFile] {
        let sdBytes = assembler.assembled(counter: MediaListCommand.sdCounter)
        let internalBytes = assembler.assembled(counter: MediaListCommand.internalCounter)
        let sd = sdBytes.isEmpty ? [] : decode(sdBytes)
        let intern = internalBytes.isEmpty ? [] : decode(internalBytes)
        let sdPaths = Set(sd.map(\.path))
        let inPaths = Set(intern.map(\.path))
        if !sd.isEmpty, !intern.isEmpty, sdPaths == inPaths {
            return stampStorage(decode(assembler.assembledMerged()), fallback: true)
        }
        if sd.isEmpty, intern.isEmpty {
            let merged = assembler.assembledMerged()
            return merged.isEmpty ? [] : stampStorage(decode(merged), fallback: true)
        }
        var out: [MediaFile] = []
        out.append(contentsOf: sd.map { stamp($0, storage: 0, group: 0) })
        out.append(contentsOf: intern.map { stamp($0, storage: 1, group: 1) })
        return out
    }

    public static func headerCount(_ bytes: [UInt8]) -> Int {
        guard bytes.count >= 4 else { return 0 }
        return Int(u32(bytes, 0))
    }

    public static func recordCount(_ bytes: [UInt8]) -> Int {
        var paths = Set<String>()
        var i = 0
        while i < bytes.count {
            if let field = readPath(bytes, i, sub: 1, prefix: "DCIM/") {
                paths.insert(field.value)
                i = field.end
            } else {
                i += 1
            }
        }
        return paths.count
    }

    /// `0c 01` immediately before the final record's `0d` name field.
    public static func hasEndMarker(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 3 else { return false }
        for i in 0..<(bytes.count - 2)
        where bytes[i] == 0x0C && bytes[i + 1] == 0x01 && bytes[i + 2] == 0x0D {
            return true
        }
        return false
    }

    public static func sliceInfo(
        assembler: MediaChunkAssembler, counter: UInt8
    ) -> MediaPageSliceInfo {
        let bytes = assembler.assembled(counter: counter)
        return MediaPageSliceInfo(
            declared: bytes.count >= 4 ? headerCount(bytes) : -1,
            records: recordCount(bytes), endMarker: hasEndMarker(bytes),
            ended: assembler.didEnd(counter: counter))
    }

    // MARK: - CompositePack

    private struct MediaAnchor {
        var pos: Int
        var end: Int
        var path: String
    }

    private static func decodeComposite(_ bytes: [UInt8]) -> [MediaFile] {
        var medias: [MediaAnchor] = []
        var i = 0
        while i < bytes.count {
            if let field = readPath(bytes, i, sub: 1, prefix: "DCIM/") {
                medias.append(MediaAnchor(pos: i, end: field.end, path: field.value))
                i = field.end
            } else {
                i += 1
            }
        }
        guard !medias.isEmpty else { return [] }

        let boundary = listBoundary(bytes, records: medias.count)
        var byPath: [String: MediaFile] = [:]
        var order: [String] = []
        for (k, media) in medias.enumerated() {
            let lo = k > 0 ? medias[k - 1].end : 0
            let hi = k + 1 < medias.count ? medias[k + 1].pos : bytes.count
            let group = (boundary > 0 && k >= boundary) ? 1 : 0
            if byPath[media.path] == nil {
                var file = resolveRecord(
                    bytes, mediaDir: media.path, selfPos: media.pos, lo: lo, hi: hi)
                file.group = group
                byPath[media.path] = file
                order.append(media.path)
            }
        }
        return order.compactMap { byPath[$0] }
    }

    private struct PathField {
        var value: String
        var end: Int
    }

    private static func readPath(
        _ bytes: [UInt8], _ i: Int, sub: UInt8, prefix: String
    ) -> PathField? {
        guard i + 6 <= bytes.count, bytes[i] == 0x1A else { return nil }
        guard bytes[i + 2] == 0, bytes[i + 3] == 0, bytes[i + 4] == 0 else { return nil }
        guard bytes[i + 5] == sub else { return nil }
        let slen = Int(bytes[i + 1]) - 6
        guard slen >= prefix.utf8.count, i + 6 + slen <= bytes.count else { return nil }
        let raw = bytes[i + 6..<i + 6 + slen]
        guard raw.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        let value = String(bytes: raw, encoding: .isoLatin1) ?? ""
        guard value.hasPrefix(prefix) else { return nil }
        return PathField(value: value, end: i + 6 + slen)
    }

    private static func listBoundary(_ bytes: [UInt8], records: Int) -> Int {
        guard bytes.count >= 4 else { return -1 }
        let declared = Int(u32(bytes, 0))
        return (declared >= 1 && declared < records) ? declared : -1
    }

    private static func resolveRecord(
        _ bytes: [UInt8], mediaDir: String, selfPos: Int, lo: Int, hi: Int
    ) -> MediaFile {
        let base = (mediaDir as NSString).lastPathComponent
        var thumb: String?
        var t = lo
        while t < hi {
            if let field = readPath(bytes, t, sub: 2, prefix: "MISC/"),
                field.value.hasSuffix(base)
            {
                thumb = field.value
                break
            }
            t += 1
        }

        var ext = ""
        var proxyExt: String?
        var n = lo
        while n < hi - 2 {
            if bytes[n] == 0x0D {
                let len = Int(bytes[n + 1])
                if len > base.utf8.count, n + 2 + len <= bytes.count {
                    let raw = bytes[n + 2..<n + 2 + len]
                    if let value = String(bytes: raw, encoding: .isoLatin1),
                        value.utf8.count > base.utf8.count + 1,
                        value.hasPrefix(base),
                        value.dropFirst(base.count).first == "."
                    {
                        let e = String(value.dropFirst(base.count + 1)).uppercased()
                        if videoExtensions.contains(e) || photoExtensions.contains(e) {
                            ext = e
                        } else if e == "LRF" || e == "LRV" || e == "XRF" {
                            proxyExt = e
                        }
                    }
                }
            }
            n += 1
        }

        var head = -1
        var m = lo
        while m < hi - 4 {
            let kind = bytes[m]
            let star = bytes[m + 1]
            if kind == 0x03 || kind == 0x00,
                star == 0xFF || star == 0xFE,
                bytes[m + 2] == 0x19, bytes[m + 3] == 0x06, m >= 8
            {
                head = m - 8
                break
            }
            m += 1
        }
        let hasMarker = head >= 0
        let isVideo = videoExtensions.contains(ext)

        // The handle at the marker's FIXED position — `u32-LE` at `(19 06) − 10`, the same tag the
        // media type is read from. Unlike the scan above this needs no guard byte to match and
        // cannot run into the next record, so it finds the stills a Pocket 3 writes with `f6`/`c7`
        // guard bytes that the scan walks straight past. Untrusted here: `withCmdHandles` promotes
        // it only where the independent base+step fit agrees. Osmosis `CameraSession.kt` (#22).
        let handleCandidate: UInt32 = {
            guard selfPos >= 17, selfPos <= bytes.count,
                bytes[selfPos - 7] == 0x19, bytes[selfPos - 6] == 0x06
            else { return 0 }
            return u32(bytes, selfPos - 17)
        }()

        var photoSize: UInt64 = 0
        var photoRes: String?
        if !isVideo {
            var q = lo
            while q < hi - 3 {
                if bytes[q] == 0xFF || bytes[q] == 0xFE,
                    bytes[q + 1] == 0x19, bytes[q + 2] == 0x06
                {
                    let mk = q + 1
                    if mk >= 14 { photoSize = UInt64(u32(bytes, mk - 14)) }
                    if base.hasPrefix("DJI_"), mk + 66 <= bytes.count {
                        let w = Int(u32(bytes, mk + 58))
                        let h = Int(u32(bytes, mk + 62))
                        if (1...60_000).contains(w), (1...60_000).contains(h) {
                            photoRes = "\(w)x\(h)"
                        }
                    }
                    break
                }
                q += 1
            }
        }

        let path = ext.isEmpty ? mediaDir : "\(mediaDir).\(ext)"
        let thumbPath =
            (thumb
                ?? mediaDir.replacingOccurrences(of: "DCIM/", with: "MISC/THM/", options: .anchored))
            + ".scr"
        let handle: UInt32 = hasMarker ? u32(bytes, head) : 0
        let size: UInt64 = {
            if isVideo, hasMarker, head >= 4 { return UInt64(u32(bytes, head - 4)) }
            return photoSize
        }()
        let fps = isVideo && hasMarker ? fpsInRange(bytes, start: head, end: hi) : nil
        let duration: Int = {
            guard isVideo, hasMarker, head + 6 <= bytes.count else { return 0 }
            return Int(bytes[head + 4]) | (Int(bytes[head + 5]) << 8)
        }()
        let resolution: String? = {
            if isVideo, hasMarker, head + 7 < bytes.count {
                return resolutionForIndex(Int(bytes[head + 7]))
            }
            return photoRes
        }()
        return MediaFile(
            path: path,
            thumbPath: thumbPath,
            handle: handle,
            sizeBytes: size,
            durationSeconds: duration,
            // Prefer the signature read where the record has one: it is the only thing that works
            // on a body whose stills carry no marker, and it agreed with the marker read
            // everywhere both fired.
            isStarred: starFlagBySignature(bytes, lo: selfPos >= 0 ? selfPos : lo, hi: hi)
                ?? starFlag(bytes, lo: lo, hi: hi),
            resolution: resolution,
            fps: fps,
            proxyPath: proxyExt.map { "\(mediaDir).\($0)" },
            handleCandidate: handleCandidate
        )
    }

    /// The favourite flag as a Pocket 3 writes it: a `00`/`01` byte after a fixed 12-byte
    /// signature that sits *after* the record's own media path, present once per record whatever
    /// the media type.
    ///
    /// `starFlag` cannot work on that body: it anchors on `[ff|fe] 19 06`, and a Pocket 3 still
    /// carries no such marker, so a favourited photo could never show a heart at any offset.
    /// Returns nil where the signature is absent, so the caller can fall back.
    ///
    /// Established in Osmosis by a controlled A/B on one card (2026-08-17): two dumps of the same
    /// nine files differing in exactly three bytes, all three being the favourites changed between
    /// them, across eighteen records agreeing with the camera's own gallery.
    private static func starFlagBySignature(_ bytes: [UInt8], lo: Int, hi: Int) -> Bool? {
        let sig: [UInt8] = [
            0x1B, 0x0A, 0x00, 0x00, 0x00, 0x02, 0x02, 0x01, 0x14, 0x02, 0x15, 0x03,
        ]
        var q = max(0, lo)
        let end = min(hi, bytes.count - sig.count - 1)
        while q <= end {
            var k = 0
            while k < sig.count, bytes[q + k] == sig[k] { k += 1 }
            if k == sig.count { return bytes[q + sig.count] == 1 }
            q += 1
        }
        return nil
    }

    /// Star byte 9 past `[ff|fe] 19 06`. Trust only `== 1` (Nano). 44/48 on Action is a length.
    ///
    /// On an Xtra that offset lands on a *length* byte — its records run `1a <len> 00 00 00 01
    /// DCIM/…` — so anything other than 0 or 1 means this is not the layout the offset was derived
    /// from. Say "not starred" rather than guess: reading a length as a flag would put a heart on
    /// every file at once. Xtra favourites therefore still do not survive a re-list; reading them
    /// needs the camera's own `0x00/0x26` favourites filter, not this decode.
    private static func starFlag(_ bytes: [UInt8], lo: Int, hi: Int) -> Bool {
        var q = lo
        while q < hi - 9 {
            if bytes[q] == 0xFF || bytes[q] == 0xFE,
                bytes[q + 1] == 0x19, bytes[q + 2] == 0x06
            {
                return bytes[q + 9] == 1
            }
            q += 1
        }
        return false
    }

    private static func resolutionForIndex(_ code: Int) -> String? {
        guard let raw = UInt8(exactly: code), let size = DJIRecordingObservations.dimensions(raw) else { return nil }
        return "\(size.width)x\(size.height)"
    }

    private static func fpsInRange(_ bytes: [UInt8], start: Int, end: Int) -> Int? {
        var fps: Int?
        var i = max(0, start)
        let stop = min(end, bytes.count) - 8
        while i <= stop {
            let den = u32(bytes, i + 4)
            if den == 1000 || den == 1001 {
                let num = u32(bytes, i)
                if (20_000...250_000).contains(num) {
                    fps = Int((Double(num) / Double(den)).rounded())
                }
            }
            i += 1
        }
        return fps
    }

    private static func withCmdHandles(_ files: [MediaFile]) -> [MediaFile] {
        var fits: [Int: (base: UInt32, step: UInt32)] = [:]
        let groups = Dictionary(grouping: files, by: \.group)
        for (group, list) in groups {
            let pts =
                list
                .filter { $0.handle != 0 && $0.sequenceNumber > 0 }
                .map { ($0.sequenceNumber, $0.handle) }
            let unique = Dictionary(pts, uniquingKeysWith: { a, _ in a })
                .map { ($0.key, $0.value) }
                .sorted { $0.0 < $1.0 }
            guard unique.count >= 2 else { continue }
            var stepCounts: [UInt32: Int] = [:]
            for idx in 1..<unique.count {
                let dSeq = unique[idx].0 - unique[idx - 1].0
                guard dSeq > 0 else { continue }
                let dHandle = unique[idx].1 &- unique[idx - 1].1
                if dHandle > 0 {
                    let step = dHandle / UInt32(dSeq)
                    if step > 0 { stepCounts[step, default: 0] += 1 }
                }
            }
            guard let step = stepCounts.max(by: { $0.value < $1.value })?.key else { continue }
            var baseCounts: [UInt32: Int] = [:]
            for (seq, handle) in unique {
                baseCounts[handle &- UInt32(seq) &* step, default: 0] += 1
            }
            guard let base = baseCounts.max(by: { $0.value < $1.value })?.key else { continue }
            fits[group] = (base, step)
        }
        guard !fits.isEmpty else { return files }
        return files.map { file in
            guard let fit = fits[file.group], file.sequenceNumber > 0 else { return file }
            var next = file
            let fitted = fit.base &+ UInt32(file.sequenceNumber) &* fit.step
            next.cmdHandle = fitted
            if file.handle == 0, file.handleCandidate != 0, file.handleCandidate == fitted {
                // Two independent sources agree: the bytes at the record's fixed marker position,
                // and a formula fitted to the handles the OTHER records exposed. That is the bar
                // for a command that destroys a file — and it is how a Pocket 3's stills become
                // deletable without inventing anything, since the handle was always in the record
                // and only the guard-byte scan refused to read it.
                next.handle = file.handleCandidate
            } else if file.handle != 0, file.handle != fitted {
                // The scan produced a handle the fit contradicts. Something is being read out of
                // the wrong place — a record-boundary overrun once handed a photo the neighbouring
                // video's handle — and there is no way to tell which of the two is right. Drop it:
                // losing delete on one file is recoverable, deleting whatever else lives at that
                // handle is not.
                next.handle = 0
            }
            return next
        }
    }

    private static func flagHandleCollisions(_ files: [MediaFile]) -> [MediaFile] {
        var counts: [UInt32: Int] = [:]
        for file in files where file.handle != 0 {
            counts[file.handle, default: 0] += 1
        }
        let shared = Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
        guard !shared.isEmpty else { return files }
        return files.map { file in
            guard shared.contains(file.handle) else { return file }
            var next = file
            next.handleShared = true
            return next
        }
    }

    private static func stampStorage(_ files: [MediaFile], fallback: Bool) -> [MediaFile] {
        files.map { file in
            var next = file
            if fallback {
                next.storage = MediaHTTP.storageGuess(
                    handle: file.handle != 0 ? file.handle : file.cmdHandle, singleSdStorage: false)
                next.storageKnown = false
            }
            return next
        }
    }

    private static func stamp(_ file: MediaFile, storage: Int, group: Int) -> MediaFile {
        var next = file
        next.storage = storage
        next.storageKnown = true
        next.group = group
        return next
    }

    private static func u32(_ bytes: [UInt8], _ i: Int) -> UInt32 {
        UInt32(bytes[i])
            | UInt32(bytes[i + 1]) << 8
            | UInt32(bytes[i + 2]) << 16
            | UInt32(bytes[i + 3]) << 24
    }
}
