import Foundation
import OpenCineMedia

/// One file from a DUML `0x00/0x27` CompositePack manifest (Osmosis `CameraFile`).
public struct MediaFile: Equatable, Sendable, Identifiable, Hashable, Codable {
    public var path: String
    public var thumbPath: String
    public var handle: UInt32
    public var cmdHandle: UInt32
    public var sizeBytes: UInt64
    public var durationSeconds: Int
    public var isStarred: Bool
    public var resolution: String?
    public var fps: Int?
    public var proxyPath: String?
    public var storage: Int
    /// True when `storage` came from the counter of a store-specific `0x26` query.
    /// Nil is retained for catalogs written before this field existed.
    public var storageKnown: Bool?
    public var group: Int
    public var handleShared: Bool
    /// The handle read at the marker's fixed position, before the base+step fit has vouched for it.
    /// Untrusted on its own — see `withCmdHandles`. Zero when the record carries no marker.
    public var handleCandidate: UInt32

    public init(
        path: String,
        thumbPath: String,
        handle: UInt32 = 0,
        cmdHandle: UInt32 = 0,
        sizeBytes: UInt64 = 0,
        durationSeconds: Int = 0,
        isStarred: Bool = false,
        resolution: String? = nil,
        fps: Int? = nil,
        proxyPath: String? = nil,
        storage: Int = 0,
        storageKnown: Bool? = nil,
        group: Int = 0,
        handleShared: Bool = false,
        handleCandidate: UInt32 = 0
    ) {
        self.path = path
        self.thumbPath = thumbPath
        self.handle = handle
        self.cmdHandle = cmdHandle
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.isStarred = isStarred
        self.resolution = resolution
        self.fps = fps
        self.proxyPath = proxyPath
        self.storage = storage
        self.storageKnown = storageKnown
        self.group = group
        self.handleShared = handleShared
        self.handleCandidate = handleCandidate
    }

    /// Store-qualified because two cards may legitimately contain the same camera path.
    public var id: String { MediaListCommand.pageKey(self) }
    public var filename: String { (path as NSString).lastPathComponent }
    public var fileExtension: String {
        (filename as NSString).pathExtension.uppercased()
    }

    public var kind: MediaKind {
        MediaKind.from(extension: fileExtension)
    }

    public var isDeletable: Bool { handle != 0 && !handleShared }

    public var favoriteHandle: UInt32 {
        handle != 0 ? handle : cmdHandle
    }

    /// `YYYYMMDDHHmmss` baked into `DJI_20260814125250_0034_D.MP4`, or split as
    /// `_YYYYMMDD_HHMMSS_` (`VID_20260916_123456_00_001.mp4`).
    public var filenameTimestamp: String? {
        if let stamp = MediaFile.group(MediaFile.timestampRegex, in: filename, at: 1) { return stamp }
        guard let day = MediaFile.group(MediaFile.dateTimeRegex, in: filename, at: 1),
            let time = MediaFile.group(MediaFile.dateTimeRegex, in: filename, at: 2)
        else { return nil }
        return day + time
    }

    public var captureDate: Date? {
        guard let stamp = filenameTimestamp, stamp.count == 14 else { return nil }
        return MediaFile.timestampFormatter.date(from: stamp)
    }

    public var dateKey: String { filenameTimestamp.map { String($0.prefix(8)) } ?? "" }

    /// `DJI_…_0034_D` sequence used to fit `base + seq × step`.
    public var sequenceNumber: Int {
        MediaFile.group(MediaFile.sequenceRegex, in: filename, at: 1).flatMap(Int.init) ?? 0
    }

    public var burstGroupKey: String? {
        MediaFile.group(MediaFile.burstRegex, in: filename, at: 1)
    }

    public var burstIndex: Int {
        MediaFile.group(MediaFile.burstRegex, in: filename, at: 2).flatMap(Int.init) ?? 0
    }

    public var isBurstLead: Bool { burstGroupKey != nil }

    private static let timestampRegex = try! NSRegularExpression(pattern: #"_(\d{14})_"#)
    private static let dateTimeRegex = try! NSRegularExpression(pattern: #"_(\d{8})_(\d{6})_"#)
    private static let sequenceRegex = try! NSRegularExpression(pattern: #"_(\d{4})_D"#)
    private static let burstRegex = try! NSRegularExpression(pattern: #"^(.+)_(\d{3})\.\w+$"#)

    private static func group(_ regex: NSRegularExpression, in string: String, at index: Int)
        -> String?
    {
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.firstMatch(in: string, options: [], range: range),
            let captured = Range(match.range(at: index), in: string)
        else { return nil }
        return String(string[captured])
    }
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()
}

public enum MediaKind: String, Sendable, Codable {
    case video
    case photo

    public static func from(extension ext: String) -> MediaKind {
        switch ext.uppercased() {
        case "JPG", "JPEG", "DNG", "HEIC", "TIF", "TIFF", "PANO":
            return .photo
        default:
            return .video
        }
    }
}

/// What the phone has for a clip. Playback grades the proxy; Share needs the original.
public enum MediaCacheGrade: String, Sendable, Equatable {
    case none
    case proxy
    case original

    public var isPlayableOffline: Bool { self != .none }
    public var isProxyOnly: Bool { self == .proxy }

    public static func resolve(hasOriginal: Bool, hasProxy: Bool) -> MediaCacheGrade {
        if hasOriginal { return .original }
        if hasProxy { return .proxy }
        return .none
    }
}

/// SoftAP HTTP `/v2` paths. Osmosis `PathAddressing` + `StorageRules`.
public enum MediaHTTP {
    public static let host = CameraSoftAP.host
    public static let port = 80

    /// `/v2?storage=&path=` query addressing, or each file at its own path.
    public enum Addressing: Sendable { case storageQuery, directPath }

    /// Where one camera serves its media. Per session, never process-wide.
    public struct Route: Sendable, Equatable {
        public var host: String
        public var addressing: Addressing

        public init(host: String, addressing: Addressing) {
            self.host = host
            self.addressing = addressing
        }

        /// The camera SoftAP `/v2` route.
        public static let cameraSoftAP = Route(host: CameraSoftAP.host, addressing: .storageQuery)
    }

    public static func pathURL(storage: Int, path: String, route: Route = .cameraSoftAP) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = route.host
        if route.addressing == .directPath {
            components.path = path.hasPrefix("/") ? path : "/" + path
            return components.url
        }
        components.path = "/v2"
        components.queryItems = [
            URLQueryItem(name: "storage", value: String(storage)),
            URLQueryItem(name: "path", value: path),
        ]
        return components.url
    }

    /// Guess `/v2?storage=` from the delete handle's `0x40000000` bit.
    /// Internal → 1, SD → 0. Pocket 3 is the single-microSD exception (`0`).
    public static func storageGuess(handle: UInt32, singleSdStorage: Bool) -> Int {
        if singleSdStorage { return 0 }
        return (handle & MediaListCommand.internalBit) != 0 ? 1 : 0
    }

    /// `/v2?storage=` for a listed clip. Pocket 3 (single microSD) is always 0,
    /// even when the manifest stamped storage 1 from the internal-handle bit or a
    /// previous GET remembered 1.
    public static func resolvedStorage(
        stamped: Int, handle: UInt32, winner: Int?, singleSdStorage: Bool
    ) -> Int {
        if singleSdStorage { return 0 }
        if let winner, winner == 0 || winner == 1 { return winner }
        if stamped == 0 || stamped == 1 { return stamped }
        return storageGuess(handle: handle, singleSdStorage: false)
    }

    public static func originalPath(_ file: MediaFile) -> String { file.path }

    /// Clip delivery / export: the original camera file, never the LRF/XRF 720p proxy.
    public static func deliveryPath(_ file: MediaFile) -> String { originalPath(file) }

    public static func thumbnailPath(_ file: MediaFile) -> String { file.thumbPath }

    /// Preview chain: listed proxy, derived `.LRF` (DJI) / `.XRF` (CAM_), then original.
    public static func previewPaths(_ file: MediaFile) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        func add(_ path: String) {
            guard seen.insert(path).inserted else { return }
            paths.append(path)
        }
        if let proxy = file.proxyPath { add(proxy) }
        if let derived = derivedProxyPath(for: file) { add(derived) }
        add(file.path)
        return paths
    }

    /// LRF/XRF sidecars only. Empty for photos and clips with no DJI proxy.
    public static func proxyPaths(_ file: MediaFile) -> [String] {
        previewPaths(file).filter { isProxyPath($0) }
    }

    public static func derivedProxyPath(for file: MediaFile) -> String? {
        guard let ext = derivedProxyExtension(filename: file.filename) else { return nil }
        let base = (file.path as NSString).deletingPathExtension
        return "\(base).\(ext)"
    }

    public static func derivedProxyExtension(filename: String) -> String? {
        if filename.hasPrefix("VID_"), filename.lowercased().hasSuffix(".mp4") { return "lrv" }
        if filename.hasPrefix("CAM_") { return "XRF" }
        if filename.hasPrefix("DJI_") { return "LRF" }
        return nil
    }

    /// Ordered `(storage, path)` pairs to try when opening a clip. Winner storage first, then
    /// the other mount; listed/derived proxy first, original last. `/v2` itself has no
    /// extension, so the player must carry [playbackMIMEType] separately.
    public static func playbackCandidates(file: MediaFile, firstStorage: Int) -> [(
        storage: Int, path: String
    )] {
        let stores = firstStorage == 0 ? [0, 1] : [1, 0]
        var out: [(storage: Int, path: String)] = []
        var seen = Set<String>()
        for path in previewPaths(file) {
            for storage in stores {
                let key = "\(storage)\0\(path)"
                if seen.insert(key).inserted {
                    out.append((storage, path))
                }
            }
        }
        return out
    }

    public static func isProxyPath(_ path: String) -> Bool {
        switch (path as NSString).pathExtension.uppercased() {
        case "LRF", "LRV", "XRF": return true
        default: return false
        }
    }

    /// AVPlayer keys off the URL path. Camera `/v2` has none, so pass this as
    /// `AVURLAssetOutOfBandMIMETypeKey`. Sidecar proxies are MP4-in-disguise.
    public static func playbackMIMEType(for path: String) -> String {
        switch (path as NSString).pathExtension.uppercased() {
        case "JPG", "JPEG": return "image/jpeg"
        case "DNG": return "image/x-adobe-dng"
        case "HEIC": return "image/heic"
        default: return "video/mp4"
        }
    }

    /// AVPlayer keys off the file extension. Sidecar `.LRF` / `.XRF` are MP4-in-disguise.
    public static func playbackCacheFileName(_ path: String) -> String {
        let raw = path.replacingOccurrences(of: "/", with: "_")
        switch (raw as NSString).pathExtension.uppercased() {
        case "MP4", "MOV":
            return raw
        default:
            return ((raw as NSString).deletingPathExtension) + ".mp4"
        }
    }
}

/// `0x00/0x26` list payloads. Byte-identical to Osmosis / Mimo.
public enum MediaListCommand {
    public static let internalBit: UInt32 = 0x4000_0000
    public static let sdStorage = 0
    public static let internalStorage = 1

    /// Store selected by the query that returned `file`, falling back to the handle bit only when
    /// the camera did not echo request counters.
    public static func store(of file: MediaFile) -> Int {
        if file.storageKnown == true { return file.storage }
        let handle = file.handle != 0 ? file.handle : file.cmdHandle
        if handle != 0 { return (handle & internalBit) == 0 ? sdStorage : internalStorage }
        return file.group == internalStorage ? internalStorage : sdStorage
    }

    /// Dedup and UI identity across pages. The same path may exist on both stores.
    public static func pageKey(_ file: MediaFile) -> String {
        "\(store(of: file)):\(file.path)"
    }

}

/// Filter / sort helpers shared by the browser (no UI).
public enum MediaLibraryQuery {
    public static func filtered(
        _ files: [MediaFile],
        tab: MediaLibraryTab,
        formats: Set<String> = [],
        resolutions: Set<String> = [],
        dateStart: String? = nil,
        dateEnd: String? = nil,
        colors: Set<UInt8> = [],
        shotColors: [String: UInt8] = [:],
        storage: Int? = nil,
        localFavorites: Set<String> = []
    ) -> [MediaFile] {
        files.filter { file in
            switch tab {
            case .all: break
            case .videos: if file.kind != .video { return false }
            case .photos: if file.kind != .photo { return false }
            case .favorites:
                if !(file.isStarred || localFavorites.contains(file.path)) { return false }
            }
            if !formats.isEmpty, !formats.contains(file.fileExtension) { return false }
            if !resolutions.isEmpty {
                let bucket = file.resolution ?? ""
                if !resolutions.contains(bucket) { return false }
            }
            if dateStart != nil || dateEnd != nil {
                if file.dateKey.isEmpty { return false }
                if let dateStart, file.dateKey < dateStart { return false }
                if let dateEnd, file.dateKey > dateEnd { return false }
            }
            if !colors.isEmpty {
                guard let code = shotColors[file.path], colors.contains(code) else { return false }
            }
            if let storage, file.storage != storage { return false }
            return true
        }
    }

    /// Gregorian civil date in the local zone. Filenames are `YYYYMMDD`, not the
    /// device calendar identifier (Thai Buddhist years would otherwise miss).
    public static func filenameCalendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Filename `YYYYMMDD` as Gregorian year-month-day. Not an instant.
    public static func dateKey(from date: Date, calendar: Calendar = filenameCalendar()) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func date(fromKey key: String, calendar: Calendar = filenameCalendar()) -> Date? {
        guard key.count == 8,
            let year = Int(key.prefix(4)),
            let month = Int(key.dropFirst(4).prefix(2)),
            let day = Int(key.suffix(2))
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    /// Offline library: keep only files the phone can play without the camera.
    public static func cachedOnly(_ files: [MediaFile], cachedPaths: Set<String>) -> [MediaFile] {
        files.filter { cachedPaths.contains($0.path) }
    }

    public static func sorted(_ files: [MediaFile], by order: MediaLibrarySort) -> [MediaFile] {
        switch order {
        case .newest:
            return files.sorted { lhs, rhs in
                (lhs.filenameTimestamp ?? "") > (rhs.filenameTimestamp ?? "")
            }
        case .oldest:
            return files.sorted { lhs, rhs in
                (lhs.filenameTimestamp ?? "") < (rhs.filenameTimestamp ?? "")
            }
        case .name:
            return files.sorted {
                $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
            }
        case .rating:
            return files.sorted { lhs, rhs in
                if lhs.isStarred != rhs.isStarred { return lhs.isStarred && !rhs.isStarred }
                return (lhs.filenameTimestamp ?? "") > (rhs.filenameTimestamp ?? "")
            }
        }
    }
}

public enum MediaLibraryTab: String, Sendable, CaseIterable {
    case all, videos, photos, favorites
}

public enum MediaLibrarySort: String, Sendable, CaseIterable {
    case newest, oldest, name, rating
}

public enum MediaClipFormatting {
    public static func durationLabel(seconds: Int) -> String {
        guard seconds > 0 else { return "0:00" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// Decimal byte labels; zero in a file manifest means an unknown size.
    public static func byteLabel(_ bytes: UInt64) -> String {
        bytes == 0 ? "" : ByteCountLabel.label(bytes)
    }
}
