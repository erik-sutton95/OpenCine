import Foundation
import OpenCineMedia

/// Opaque source-supplied grouping for an original, its proxies and their progress presentation.
/// It is independent of a catalog asset ID; an unindexed native request does not create a row.
public struct MonitorMediaLibraryIOKey: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ value: String) { rawValue = value }
}

public enum MonitorMediaLibraryIOPurpose: Hashable, Sendable {
    case thumbnail, download, playback, originalImage, deletion

    var tracksProgress: Bool { self == .download || self == .playback }
}

/// Captured library, content, root and SDK admission. No future camera or cache generation can
/// inherit this authority. The actual source predicate is evaluated on the presentation owner.
@MainActor public final class MonitorMediaLibraryIOAuthority {
    public let id = UUID()
    public let key: MonitorMediaLibraryIOKey
    public let asset: MediaAssetID?
    public let directory: MonitorMediaCacheDirectory
    public let generation: UInt64
    let owner: UUID
    private let admitted: @MainActor () -> Bool

    init(owner: UUID, key: MonitorMediaLibraryIOKey, asset: MediaAssetID?,
        directory: MonitorMediaCacheDirectory, admitted: @escaping @MainActor () -> Bool) {
        self.owner = owner
        self.key = key
        self.asset = asset
        self.directory = directory
        generation = directory.generation
        self.admitted = admitted
    }
    public var isCurrent: Bool {
        guard !Task.isCancelled, directory.generation == generation else { return false }
        let allowed = admitted()
        return allowed && !Task.isCancelled && directory.generation == generation
    }
    public func requireCurrent() throws {
        try Task.checkCancellation()
        guard isCurrent else { throw MediaServiceError.retired }
    }
}

/// Bounded local file handoff for existing SDK staging ports. File reads run off the owner;
/// cache/sink admission and cancellation remain with the captured transfer.
enum MonitorMediaLibraryFileCopy {
    static func copy(_ source: URL, into sink: any MediaByteSink) async throws -> UInt64 {
        let worker = Task.detached {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            var count: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let bytes = try input.read(upToCount: 64 * 1024) ?? Data()
                if bytes.isEmpty { return count }
                try await sink.write(bytes)
                count += UInt64(bytes.count)
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }
}
