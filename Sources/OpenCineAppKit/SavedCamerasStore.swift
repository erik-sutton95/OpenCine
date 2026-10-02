import Foundation
import OpenCineCore

/// One stored value in the app's own namespace (a defaults key, a file).
public struct StoredData {
    public var read: () -> Data?
    public var write: (Data) -> Void

    public init(read: @escaping () -> Data?, write: @escaping (Data) -> Void) {
        self.read = read
        self.write = write
    }

    public static func userDefaults(_ defaults: UserDefaults = .standard, key: String) -> StoredData {
        StoredData(read: { defaults.data(forKey: key) }, write: { defaults.set($0, forKey: key) })
    }
}

/// The saved cameras of one app: a versioned document plus, while older builds may still run,
/// the legacy records it was migrated from, kept mirrored.
///
/// - `load()` merges the legacy records into the document (three-way, per
///   `SavedCamerasDocument.merge`) and writes only the document; legacy bytes are never written
///   by a read.
/// - `save(_:)` patches the legacy records first, then writes the document with the new merge
///   base, so a crash between the two writes is merged back on the next launch.
/// - A document from a newer build is never written: this build runs from legacy.
/// - Credentials and every other per-camera store are never read or written here.
@MainActor
public final class SavedCamerasStore {
    public struct Legacy {
        public var data: StoredData
        public var codec: any LegacySavedCameraCodec
        /// The merge-base name of this source in the document.
        public var source: String

        public init(data: StoredData, codec: any LegacySavedCameraCodec, source: String) {
            self.data = data
            self.codec = codec
            self.source = source
        }
    }

    public private(set) var cameras: [SavedCamera] = []
    /// `false` while the stored document is from a newer build.
    public private(set) var writesDocument = true
    private var document = SavedCamerasDocument()
    private let stored: StoredData
    private let legacy: Legacy?

    public init(document: StoredData, legacy: Legacy? = nil) {
        self.stored = document
        self.legacy = legacy
    }

    public func load() {
        let data = stored.read()
        if let data, let version = try? JSONDecoder().decode(Version.self, from: data).version,
            version > SavedCamerasDocument.currentVersion
        {
            writesDocument = false
            document = SavedCamerasDocument()
        } else {
            writesDocument = true
            document = data.flatMap { try? Self.decoder.decode(SavedCamerasDocument.self, from: $0) }
                ?? SavedCamerasDocument()
        }
        if let legacy, let records = legacy.data.read().flatMap(legacy.codec.cameras(in:)) {
            document.merge(
                records, from: legacy.source, heldExtras: legacy.codec.heldExtras,
                holdsRouteTitles: legacy.codec.holdsRouteTitles)
        }
        cameras = document.cameras
        guard writesDocument, let encoded = try? Self.encoder.encode(document), encoded != data else { return }
        stored.write(encoded)
    }

    public func save(_ cameras: [SavedCamera]) {
        document.cameras = cameras
        self.cameras = cameras
        if let legacy, let patched = legacy.codec.patched(legacy.data.read(), to: cameras) {
            legacy.data.write(patched)
            document.recordMirror(legacy.codec.cameras(in: patched) ?? [], from: legacy.source)
        }
        guard writesDocument, let encoded = try? Self.encoder.encode(document) else { return }
        stored.write(encoded)
    }

    private struct Version: Decodable { var version: Int }

    /// Sorted keys and epoch milliseconds, as the Kotlin store writes.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}
