#if os(iOS)
import MonitorUI
import OpenCineApple
import OpenCineCameraVocabulary
import OpenCineMedia
import SwiftUI
import UIKit

@MainActor
enum MediaCellThumbnailCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 150
        return cache
    }()
}


/// Where a gallery cell finds a clip's cached thumbnail and asks the camera for one.
/// Kotlin twin: `MonitorMediaThumbnailSource` in camera-controls.
@MainActor public protocol MonitorMediaThumbnailSource: AnyObject {
    /// Fetches and caches the thumbnail when the source can; `thumbnailURL(for:)` reads it after.
    func ensureThumbnail(for file: MediaFile) async
    func thumbnailURL(for file: MediaFile) -> URL?
    /// Thumbnail bytes the connected camera serves directly, or nil when it serves none now.
    func thumbnailBytes(for file: MediaFile) async -> Data?
}

extension MonitorMediaThumbnailSource {
    public func thumbnailBytes(for file: MediaFile) async -> Data? { nil }
}

/// The gallery cell's picture: a bounded thumbnail decode, else the photo or film glyph. The
/// common catalog owns its admission. Kotlin twin: `MonitorMediaCatalogPicture`.
public struct MonitorMediaCatalogThumbnail: View {
    let cameraID: String
    /// The clip's stable id in this camera's catalog (cell identity and cache key).
    let assetID: String
    let file: MediaFile
    let cacheGrade: MediaCacheGrade
    let localURL: URL?
    let thumbnailURL: URL?
    let isCurrent: () -> Bool
    let onDuration: (String) -> Void
    let source: @MainActor () -> any MonitorMediaThumbnailSource
    @State private var thumbnail: UIImage?

    public init(
        cameraID: String, assetID: String, file: MediaFile, cacheGrade: MediaCacheGrade,
        localURL: URL?, thumbnailURL: URL?, isCurrent: @escaping () -> Bool,
        onDuration: @escaping (String) -> Void,
        source: @escaping @MainActor () -> any MonitorMediaThumbnailSource
    ) {
        self.cameraID = cameraID
        self.assetID = assetID
        self.file = file
        self.cacheGrade = cacheGrade
        self.localURL = localURL
        self.thumbnailURL = thumbnailURL
        self.isCurrent = isCurrent
        self.onDuration = onDuration
        self.source = source
    }

    private var isPhoto: Bool { file.kind == .photo }
    private var isDownloaded: Bool { cacheGrade == .original }

    public var body: some View {
        ZStack {
            MonitorTheme.surface
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
            } else {
                (isPhoto ? MonitorIcon.image : MonitorIcon.film)
                    .frame(width: 28, height: 28).foregroundStyle(MonitorTheme.faint)
            }
        }
        .clipped()
        .task(
            id:
                "\(cameraID)#\(assetID)#\(thumbnailURL?.path ?? "")#\(localURL?.path ?? "")#\(cacheGrade.rawValue)"
        ) {
            thumbnail = nil
            await loadThumbnail()
            await loadDuration()
        }
    }

    private func loadThumbnail() async {
        let cacheKey = "\(cameraID)#\(assetID)#grid" as NSString
        guard isCurrent(), !Task.isCancelled else { return }
        if let cached = MediaCellThumbnailCache.shared.object(forKey: cacheKey) {
            thumbnail = cached
            return
        }
        func present(_ image: UIImage) {
            guard isCurrent(), !Task.isCancelled else { return }
            MediaCellThumbnailCache.shared.setObject(image, forKey: cacheKey)
            thumbnail = image
        }
        if let thumbnailURL,
            let image = await MediaCellImageLoader.shared.downsampled(
                at: thumbnailURL, maxPixelSize: 640)
        {
            present(image)
            return
        }
        if isPhoto, isDownloaded, let localURL,
            let image = await MediaCellImageLoader.shared.downsampled(
                at: localURL, maxPixelSize: 640)
        {
            present(image)
            return
        }
        guard isCurrent(), !Task.isCancelled else { return }
        await source().ensureThumbnail(for: file)
        guard isCurrent(), !Task.isCancelled else { return }
        if let cachedURL = source().thumbnailURL(for: file),
            let image = await MediaCellImageLoader.shared.downsampled(
                at: cachedURL, maxPixelSize: 640)
        {
            present(image)
            return
        }
        guard isCurrent(), !Task.isCancelled else { return }
        if let data = await source().thumbnailBytes(for: file),
            let image = await MediaCellImageLoader.shared.downsampled(data: data, maxPixelSize: 640)
        {
            present(image)
            return
        }
        guard isCurrent(), !Task.isCancelled, isDownloaded, !isPhoto, let localURL else { return }
        if let image = await MediaCellVideoFrames.poster(at: localURL) {
            present(image)
        }
    }

    private func loadDuration() async {
        guard isCurrent(), !Task.isCancelled, !isPhoto else { return }
        if file.durationSeconds > 0 {
            onDuration(MediaClipFormatting.durationLabel(seconds: file.durationSeconds))
            return
        }
        guard isDownloaded, let localURL else { return }
        if let seconds = await MediaCellVideoFrames.durationSeconds(at: localURL), isCurrent(), !Task.isCancelled {
            onDuration(MediaClipFormatting.durationLabel(seconds: Int(seconds)))
        }
    }
}
#endif
