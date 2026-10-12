#if os(iOS)
import Foundation
import OpenCineMedia
import Photos

public enum MonitorDeliveryNativeFileFailure: LocalizedError {
    case photosDenied, emptySelection
    public var errorDescription: String? {
        switch self {
        case .photosDenied: "Photos access is required to save the clip."
        case .emptySelection: "Select at least one clip."
        }
    }
}
/// One native OS transaction. Permission may suspend; retired work cannot enter creation afterward.
@MainActor public enum MonitorDeliveryPhotosSaver {
    /// Saves movies as videos and stills (delivered as originals) as photos.
    public static func save(at urls: [URL], ifCurrent: @MainActor () -> Bool = { true }) async throws -> Int {
        guard !Task.isCancelled, ifCurrent(), !Task.isCancelled else { throw CancellationError() }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard !Task.isCancelled, ifCurrent(), !Task.isCancelled else { throw CancellationError() }
        guard status == .authorized || status == .limited else { throw MonitorDeliveryNativeFileFailure.photosDenied }
        let videos = urls.filter { MonitorMediaShareStaging.videoExtensions.contains($0.pathExtension.lowercased()) }
        let stills = urls.filter(MonitorMediaShareStaging.isStill)
        guard !Task.isCancelled, ifCurrent(), !Task.isCancelled else { throw CancellationError() }
        // Entered PHPhotoLibrary work retains its actual OS transaction contract. Immutable
        // selection also preserves the prior count without a mutable cross-executor counter.
        // PhotoKit runs the block on its own queue, so it must not inherit main-actor isolation
        // (Swift 6 traps on entry otherwise: OPENPOCKETCINE-IOS-3P).
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            for url in videos { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
            for url in stills { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) }
        }
        return videos.count + stills.count
    }
}
/// The deployed share selection returns the camera/export files themselves and no disposable root.
public enum MonitorDeliveryShareStaging {
    public static let shareableVideoExtensions: Set<String> = MonitorMediaShareStaging.videoExtensions
    /// Movies and stills reach the share sheet; sidecars and other files do not.
    public static func prepareForShare(urls: [URL]) throws -> (urls: [URL], stagingCleanupURL: URL?) {
        let files = urls.filter {
            shareableVideoExtensions.contains($0.pathExtension.lowercased()) || MonitorMediaShareStaging.isStill($0)
        }
        guard !files.isEmpty else { throw MonitorDeliveryNativeFileFailure.emptySelection }
        return (files, nil)
    }
}
#endif
