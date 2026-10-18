#if os(iOS)
import Foundation
import OpenCineAppKit
import OpenCineMedia
import Photos

/// Photos save for every app (A2-56): add-only access is asked before any cache or export work,
/// and each item is its own OS insert, so a rejected item never discards the others.
@MainActor public enum MonitorDeliveryPhotosSaver {
    public enum SaveError: LocalizedError {
        case permissionDenied
        case saveFailed(String)
        public var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "Photo library access is required to save clips. Enable it in Settings."
            case .saveFailed(let name): "Couldn't save \(name) to Photos."
            }
        }
    }

    /// The access request the batch admits before caching or exporting anything.
    public static var authorization: MonitorDeliveryPhotosAuthorizationService {
        .init(
            isPending: { PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined },
            authorize: {
                switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
                case .authorized, .limited: return
                case .notDetermined:
                    let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    guard granted == .authorized || granted == .limited else {
                        throw SaveError.permissionDenied
                    }
                default: throw SaveError.permissionDenied
                }
            })
    }

    /// One validated insert: a movie as a video, a still original as a photo.
    public static var service: MonitorDeliveryPhotosService<URL> {
        .init { url in
            try MonitorMediaShareStaging.validateShareableFile(at: url)
            try await save(at: url)
            return true
        }
    }

    /// Compatibility for the earlier array API; new delivery batches compose authorization and
    /// the per-file service. Both paths use the same nonisolated PhotoKit change block (PI-3P).
    public static func save(at urls: [URL], ifCurrent: @MainActor () -> Bool = { true }) async throws -> Int {
        guard !Task.isCancelled, ifCurrent(), !Task.isCancelled else { throw CancellationError() }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard !Task.isCancelled, ifCurrent(), !Task.isCancelled else { throw CancellationError() }
        guard status == .authorized || status == .limited else { throw SaveError.permissionDenied }
        let videos = urls.filter { MonitorMediaShareStaging.videoExtensions.contains($0.pathExtension.lowercased()) }
        let stills = urls.filter(MonitorMediaShareStaging.isStill)
        guard !Task.isCancelled, ifCurrent(), !Task.isCancelled else { throw CancellationError() }
        try await performChanges(failureName: "selection") {
            for url in videos { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
            for url in stills { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) }
        }
        return videos.count + stills.count
    }

    static func save(at url: URL) async throws {
        try await performChanges(failureName: url.lastPathComponent) {
            PHAssetCreationRequest.forAsset().addResource(
                with: MonitorMediaShareStaging.isStill(url) ? .photo : .video,
                fileURL: url, options: nil)
        }
    }

    // PhotoKit invokes this on its own queue. The typed Sendable block prevents inheriting the
    // saver's main actor for both the compatibility transaction and each new per-file insert.
    private static func performChanges(failureName: String,
        _ changes: @escaping @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(
                changes,
                completionHandler: { success, error in
                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: error ?? SaveError.saveFailed(failureName))
                    }
                })
        }
    }
}
#endif
