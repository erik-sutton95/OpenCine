import Foundation
import OpenCineCore
import OpenCineMedia

/// Immutable actual source fields. No cache address or identity is inferred from id.
public struct NikonGallerySourceItem: Sendable {
    public let id: MediaAssetID
    public let legacyID: String
    public let namespace: String
    public let filename: String
    public let captureDate: String
    public let pixelWidth: UInt32?
    public let pixelHeight: UInt32?
    public let sourcePixelWidth: UInt32?
    public let storageID: UInt32?
    public let storageMembership: Set<UInt32>?
    public let handle: UInt32?
    public let favorite: Bool
    public let rating: Int?
    public let localEligible: Bool?
    public init(
        id: MediaAssetID, legacyID: String, namespace: String, filename: String,
        captureDate: String, pixelWidth: UInt32?, pixelHeight: UInt32?, sourcePixelWidth: UInt32?,
        storageID: UInt32?, storageMembership: Set<UInt32>?, handle: UInt32?, favorite: Bool,
        rating: Int?, localEligible: Bool?
    ) {
        self.id = id
        self.legacyID = legacyID
        self.namespace = namespace
        self.filename = filename
        self.captureDate = captureDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sourcePixelWidth = sourcePixelWidth
        self.storageID = storageID
        self.storageMembership = storageMembership
        self.handle = handle
        self.favorite = favorite
        self.rating = rating
        self.localEligible = localEligible
    }
    fileprivate var pairKey: String {
        "\(namespace)/\(storageID.map(String.init) ?? "-")/\(MediaClipFilename.stem(of: filename))"
    }
    fileprivate var raw: Bool { MediaClipFilename.formatChip(for: filename) == .nef }
    fileprivate var jpeg: Bool { MediaClipFilename.formatChip(for: filename) == .jpeg }
    fileprivate var sortKey: String { captureDate.isEmpty ? filename : captureDate }
    fileprivate var burstFrame: BurstFrame {
        .init(
            id: legacyID, storageID: storageID, handle: handle, captureDate: captureDate,
            stem: MediaClipFilename.stem(of: filename).lowercased(), isRaw: raw,
            formatKey:
                "\((filename as NSString).pathExtension.lowercased())|\(pixelWidth.map(String.init) ?? "?")x\(pixelHeight.map(String.init) ?? "?")"
        )
    }
}

/// Finite source-policy stages for the proposed neutral projection port.
/// MonitorMediaProjectionPolicy/values live in Media; their implementation has one separate writer.
public struct NikonAppleGalleryProjectionPolicy: MonitorMediaProjectionPolicy {
    public let groupStage = MonitorMediaProjectionGroupStage.beforeSort
    private let items: [NikonGallerySourceItem]
    private let byID: [MediaAssetID: NikonGallerySourceItem]
    /// The first RAW of each pair key, in item order: what `rawCompanion` answers per cell.
    private let firstRawByPairKey: [String: MediaAssetID]
    private let now: Date
    private let calendar: Calendar
    public init(items: [NikonGallerySourceItem], now: Date, calendar: Calendar) {
        self.items = items
        self.now = now
        self.calendar = calendar
        byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var firstRaw: [String: MediaAssetID] = [:]
        for item in items where item.raw && firstRaw[item.pairKey] == nil {
            firstRaw[item.pairKey] = item.id
        }
        firstRawByPairKey = firstRaw
    }
    public func prepareCategory(_ ids: [MediaAssetID], category: MonitorMediaProjectionCategory)
        -> MonitorMediaProjectionCategoryFacts
    {
        let candidates = ids.compactMap { byID[$0] }
        let proxyStems = MediaClipFilename.playableProxyStems(in: candidates.map(\.filename))
        let visible = candidates.filter {
            MediaClipFilename.shouldShowInMediaBrowser(
                filename: $0.filename, playableProxyStems: proxyStems)
        }
        let scoped = visible.filter { item in
            switch category {
            case .all: return true
            case .videos: return MediaClipFilename.isPlayableProxy(item.filename)
            case .photos: return MediaClipFilename.isPhoto(item.filename)
            case .favorites: return item.favorite
            }
        }
        let widths = scoped.compactMap {
            MediaClipFilename.isPhoto($0.filename) ? $0.pixelWidth : nil
        }
        // One ranking and one date classification per listing, not per photo.
        let ranking = NikonMediaPhotoSizeClass.ranking(among: widths)
        var classifier = NikonMediaDateWindowClassifier(now: now, calendar: calendar)
        let rows = scoped.map { item -> MonitorMediaProjectionFacts in
            let photo = MediaClipFilename.isPhoto(item.filename)
            let photoSize = photo ? item.pixelWidth.flatMap { $0 > 0 ? ranking[$0] : nil } : nil
            let windows = classifier.windows(item.captureDate).map { Set($0.map(\.rawValue)) }
            return .init(
                id: item.id, format: MediaClipFilename.formatChip(for: item.filename)?.rawValue,
                resolution: NikonMediaResolutionBucket.classify(
                    filename: item.filename,
                    pixelWidth: item.pixelWidth, sourcePixelWidth: item.sourcePixelWidth)?.rawValue,
                photoSize: photoSize?.rawValue, dateWindows: windows,
                storageMembership: item.storageMembership.map { Set($0.map(String.init)) },
                pair: item.jpeg
                    ? .init(identity: item.pairKey, role: .preferred)
                    : (item.raw ? .init(identity: item.pairKey, role: .companion) : nil),
                localEligible: item.localEligible, rating: item.rating)
        }
        let offered = NikonMediaFilterDerivation.options(
            for: scoped.map {
                .init(
                    filename: $0.filename, pixelWidth: $0.pixelWidth,
                    sourcePixelWidth: $0.sourcePixelWidth, captureDate: $0.captureDate)
            }, now: now, calendar: calendar)
        return .init(
            rows: rows,
            offered: .init(
                formats: offered.formats.map(\.rawValue),
                resolutions: offered.resolutions.map(\.rawValue),
                photoSizes: offered.photoSizes.map(\.rawValue),
                dateWindows: offered.dateWindows.map(\.rawValue)))
    }
    public func compare(_ lhs: MediaAssetID, _ rhs: MediaAssetID, sort: MonitorMediaProjectionSort)
        -> ComparisonResult
    {
        guard let left = byID[lhs], let right = byID[rhs] else { return .orderedSame }
        return Self.compare(left, right, sort: sort)
    }
    public static func compare(
        _ left: NikonGallerySourceItem, _ right: NikonGallerySourceItem,
        sort: MonitorMediaProjectionSort
    ) -> ComparisonResult {
        switch sort {
        case .name: return left.filename.localizedCaseInsensitiveCompare(right.filename)
        case .rating:
            let ls = left.rating ?? 0
            let rs = right.rating ?? 0
            if ls != rs { return ls > rs ? .orderedAscending : .orderedDescending }
            fallthrough
        case .newest:
            if left.sortKey != right.sortKey {
                return left.sortKey > right.sortKey ? .orderedAscending : .orderedDescending
            }
            let name = left.filename.localizedCaseInsensitiveCompare(right.filename)
            return name == .orderedAscending
                ? .orderedDescending
                : (name == .orderedDescending ? .orderedAscending : .orderedSame)
        case .oldest:
            if left.sortKey != right.sortKey {
                return left.sortKey < right.sortKey ? .orderedAscending : .orderedDescending
            }
            return left.filename.localizedCaseInsensitiveCompare(right.filename)
        }
    }
    public func groups(_ ids: [MediaAssetID]) -> [MonitorMediaProjectionGroup] {
        let survivors = ids.compactMap { byID[$0] }
        let byLegacy = Dictionary(
            survivors.map { ($0.legacyID, $0.id) }, uniquingKeysWith: { first, _ in first })
        return BurstSeriesGrouping.group(survivors.map(\.burstFrame)).compactMap { run in
            guard let representative = byLegacy[run.representativeID] else { return nil }
            return .init(
                representative: representative, members: run.memberIDs.compactMap { byLegacy[$0] })
        }
    }
    /// Unfiltered lookup remains available to unchanged native RAW widening/viewer operations.
    /// The gallery asks it for every cell on each render, so it never rescans the library
    /// (OPENZCINE-IOS-6/-7).
    public func rawCompanion(of id: MediaAssetID) -> MediaAssetID? {
        guard let item = byID[id], item.jpeg else { return nil }
        return firstRawByPairKey[item.pairKey]
    }
}
