#if os(iOS)
import Foundation
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
    public static func saveVideos(at urls: [URL], ifCurrent: @MainActor () -> Bool = { true }) async throws -> Int {
        guard !Task.isCancelled, ifCurrent(), !Task.isCancelled else { throw CancellationError() }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard !Task.isCancelled, ifCurrent(), !Task.isCancelled else { throw CancellationError() }
        guard status == .authorized || status == .limited else { throw MonitorDeliveryNativeFileFailure.photosDenied }
        let videos = urls.filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
        guard !Task.isCancelled, ifCurrent(), !Task.isCancelled else { throw CancellationError() }
        // Entered PHPhotoLibrary work retains its actual OS transaction contract. Immutable
        // selection also preserves the prior count without a mutable cross-executor counter.
        // PhotoKit runs the block on its own queue, so it must not inherit main-actor isolation
        // (Swift 6 traps on entry otherwise: OPENPOCKETCINE-IOS-3P).
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            for url in videos { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
        }
        return videos.count
    }
}
/// The deployed share selection returns the camera/export files themselves and no disposable root.
public enum MonitorDeliveryShareStaging {
    public static let shareableVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    public static func prepareForShare(videoURLs: [URL]) throws -> (urls: [URL], stagingCleanupURL: URL?) {
        let videos = videoURLs.filter { shareableVideoExtensions.contains($0.pathExtension.lowercased()) }
        guard !videos.isEmpty else { throw MonitorDeliveryNativeFileFailure.emptySelection }
        return (videos, nil)
    }
}
#endif
