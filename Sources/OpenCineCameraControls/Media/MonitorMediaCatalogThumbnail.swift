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

/// The catalog's artwork and admitted async publication. Native loaders and placeholder content
/// arrive from the source; Kotlin twin: `MonitorMediaCatalogArtwork`.
public struct MonitorMediaCatalogArtwork<Identity: Hashable, Reload: Hashable, Placeholder: View>: View {
    private struct Request: Equatable {
        let identity: Identity
        let reload: Reload
    }
    private let identity: Identity
    private let reload: Reload
    private let isCurrent: @MainActor () -> Bool
    private let load: @MainActor () async -> UIImage?
    private let afterLoad: @MainActor () async -> Void
    private let placeholder: @MainActor () -> Placeholder
    @State private var thumbnail: UIImage?
    @State private var presentedIdentity: Identity?

    /// `identity` retains an image for one source; `reload` restarts loading without discarding it.
    /// `afterLoad` reads metadata only after the image is published for the current admission.
    public init(identity: Identity, reload: Reload, isCurrent: @escaping @MainActor () -> Bool,
        load: @escaping @MainActor () async -> UIImage?,
        afterLoad: (@MainActor () async -> Void)? = nil,
        @ViewBuilder placeholder: @escaping @MainActor () -> Placeholder) {
        self.identity = identity; self.reload = reload; self.isCurrent = isCurrent; self.load = load
        // Resolved here, not as a closure-literal default (swiftlang/swift#92017).
        self.afterLoad = afterLoad ?? {}; self.placeholder = placeholder
    }

    public var body: some View {
        ZStack {
            MonitorTheme.surface
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
            } else { placeholder() }
        }
        .clipped()
        .task(id: Request(identity: identity, reload: reload)) {
            if presentedIdentity != identity {
                thumbnail = nil
                presentedIdentity = identity
            }
            guard isCurrent(), !Task.isCancelled else { return }
            let loaded = await load()
            guard isCurrent(), !Task.isCancelled else { return }
            thumbnail = loaded
            await afterLoad()
        }
    }
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
        MonitorMediaCatalogArtwork(
            identity: "\(cameraID)#\(assetID)#\(thumbnailURL?.path ?? "")#\(localURL?.path ?? "")#\(cacheGrade.rawValue)",
            reload: 0,
            isCurrent: isCurrent, load: loadThumbnail, afterLoad: loadDuration
        ) {
            (isPhoto ? MonitorIcon.image : MonitorIcon.film)
                .frame(width: 28, height: 28).foregroundStyle(MonitorTheme.faint)
        }
    }

    private func loadThumbnail() async -> UIImage? {
        let cacheKey = "\(cameraID)#\(assetID)#grid" as NSString
        guard isCurrent(), !Task.isCancelled else { return nil }
        if let cached = MediaCellThumbnailCache.shared.object(forKey: cacheKey) {
            return cached
        }
        func present(_ image: UIImage) -> UIImage? {
            guard isCurrent(), !Task.isCancelled else { return nil }
            MediaCellThumbnailCache.shared.setObject(image, forKey: cacheKey)
            return image
        }
        if let thumbnailURL,
            let image = await MediaCellImageLoader.shared.downsampled(
                at: thumbnailURL, maxPixelSize: 640)
        {
            return present(image)
        }
        if isPhoto, isDownloaded, let localURL,
            let image = await MediaCellImageLoader.shared.downsampled(
                at: localURL, maxPixelSize: 640)
        {
            return present(image)
        }
        guard isCurrent(), !Task.isCancelled else { return nil }
        await source().ensureThumbnail(for: file)
        guard isCurrent(), !Task.isCancelled else { return nil }
        if let cachedURL = source().thumbnailURL(for: file),
            let image = await MediaCellImageLoader.shared.downsampled(
                at: cachedURL, maxPixelSize: 640)
        {
            return present(image)
        }
        guard isCurrent(), !Task.isCancelled else { return nil }
        if let data = await source().thumbnailBytes(for: file),
            let image = await MediaCellImageLoader.shared.downsampled(data: data, maxPixelSize: 640)
        {
            return present(image)
        }
        guard isCurrent(), !Task.isCancelled, isDownloaded, !isPhoto, let localURL else { return nil }
        if let image = await MediaCellVideoFrames.poster(at: localURL) {
            return present(image)
        }
        return nil
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
