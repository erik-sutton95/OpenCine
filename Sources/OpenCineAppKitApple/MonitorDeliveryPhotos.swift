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

    static func save(at url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(
                {
                    PHAssetCreationRequest.forAsset().addResource(
                        with: MonitorMediaShareStaging.isStill(url) ? .photo : .video,
                        fileURL: url, options: nil)
                },
                completionHandler: { success, error in
                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: error ?? SaveError.saveFailed(url.lastPathComponent))
                    }
                })
        }
    }
}
#endif
