import Foundation
import OpenCineMedia

public enum MonitorMediaCacheError: Error, Equatable, Sendable {
    case retired, invalidAddress, empty, invalidReceipt
}

/// Cache addresses are explicit codec inputs, never extracted from an opaque source identity.
public struct MonitorMediaCacheAddress: Equatable, Sendable {
    public let thumbnail: String
    public let representations: [MediaRepresentationID: String]
    public let favoriteKey: String
    public init(thumbnail: String, representations: [MediaRepresentationID: String], favoriteKey: String) {
        self.thumbnail = thumbnail; self.representations = representations; self.favoriteKey = favoriteKey
    }
}

/// Immutable source or legacy preservation payload. Only the app's codec interprets Payload.
public struct MonitorMediaRecord<Payload: Sendable>: Sendable {
    public let asset: MediaAsset
    public let payload: Payload
    public let address: MonitorMediaCacheAddress
    public var favorite: Bool
    public let facts: MonitorMediaFilterFacts
    public init(asset: MediaAsset, payload: Payload, address: MonitorMediaCacheAddress, favorite: Bool = false, facts: MonitorMediaFilterFacts = .init()) {
        self.asset = asset; self.payload = payload; self.address = address; self.favorite = favorite; self.facts = facts
    }
}

@MainActor public protocol MonitorMediaCatalogCodec<Payload>: Sendable {
    associatedtype Payload: Sendable
    func decode(_ bytes: Data) throws -> [MonitorMediaRecord<Payload>]
    func encode(_ records: [MonitorMediaRecord<Payload>]) throws -> Data
    /// Capture immediately after a fenced delta, before encoding/IO can suspend.
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<Payload>
}

public enum MonitorMediaOriginalEligibility: Equatable, Sendable {
    case exactSize, minimumFraction(numerator: UInt64, denominator: UInt64)
    public func accepts(bytes: UInt64, expected: UInt64?) -> Bool {
        guard bytes > 0 else { return false }
        guard let expected, expected > 0 else { return true }
        switch self {
        case .exactSize: return bytes == expected
        case .minimumFraction(let numerator, let denominator):
            guard denominator > 0, numerator <= denominator else { return false }
            let minimum = denominator.dividingFullWidth(expected.multipliedFullWidth(by: numerator)).quotient
            return bytes >= minimum
        }
    }
}

public struct MonitorMediaCacheEntry: Sendable {
    public let originalURL: URL?
    public let proxyURL: URL?
    public let thumbnailURL: URL?
    public var isPlayableOffline: Bool { originalURL != nil || proxyURL != nil }
}

/// Root lifetime shared explicitly by the cache/library owners for that namespace. No globals.
@MainActor public final class MonitorMediaCacheDirectory {
    public let root: URL
    private let manager: FileManager
    fileprivate let writes = MediaCacheWrites()
    public var generation: UInt64 { writes.withLock { writes.generation } }
    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root; manager = fileManager
    }

    public func url(_ address: String) throws -> URL {
        let pieces = address.split(separator: "/", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            !address.contains("\\") else { throw MonitorMediaCacheError.invalidAddress }
        return root.appendingPathComponent(address)
    }
    public func read(_ address: String) throws -> Data { try Data(contentsOf: url(address)) }
    public func write(_ data: Data, at address: String) throws {
        let destination = try url(address)
        try writes.withLock {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let previous = writes.current.removeValue(forKey: destination.path),
                let resource = writes.resources.removeValue(forKey: previous) {
                try? resource.handle.close(); try? manager.removeItem(at: resource.temporary)
            }
            try data.write(to: destination, options: .atomic)
        }
    }
    public func existing(_ address: String) -> URL? {
        guard let destination = try? url(address),
            let info = try? manager.attributesOfItem(atPath: destination.path),
            info[.type] as? FileAttributeType == .typeRegular,
            (info[.size] as? NSNumber)?.uint64Value ?? 0 > 0 else { return nil }
        return destination
    }
    public func byteCount(_ address: String) -> UInt64 {
        guard let destination = try? url(address) else { return 0 }
        return ((try? manager.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.uint64Value ?? 0
    }
    public func beginWrite(at address: String) throws -> MonitorMediaCacheWrite {
        let destination = try url(address)
        return try writes.withLock {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let id = UUID()
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(id.uuidString + ".part")
            guard manager.createFile(atPath: temporary.path, contents: nil) else { throw MonitorMediaCacheError.empty }
            let handle = try FileHandle(forWritingTo: temporary)
            if let previous = writes.current[destination.path], let resource = writes.resources.removeValue(forKey: previous) {
                try? resource.handle.close(); try? manager.removeItem(at: resource.temporary)
            }
            writes.current[destination.path] = id
            writes.resources[id] = .init(handle: handle, temporary: temporary)
            return MonitorMediaCacheWrite(id: id, generation: writes.generation, destination: destination,
                temporary: temporary, handle: handle, writes: writes, manager: manager)
        }
    }

    /// Invalidate writers and retire the directory before yielding. Deletion sees captured retired
    /// roots only; it never walks a live path created by a later transfer or Clear.
    public func clear(preserving names: [String]) async throws {
        let root = root, manager = manager
        let pending: [URL] = try writes.withLock {
            writes.generation &+= 1; writes.current.removeAll()
            for resource in writes.resources.values { try? resource.handle.close() }
            writes.resources.removeAll()
            if manager.fileExists(atPath: root.path) {
                let suffix = root.lastPathComponent + "-" + UUID().uuidString
                let retired = root.deletingLastPathComponent().appendingPathComponent(".retiring-" + suffix)
                let ready = root.deletingLastPathComponent().appendingPathComponent(".clearing-" + suffix)
                try manager.moveItem(at: root, to: retired)
                var moved: [String] = []
                do {
                    if !names.isEmpty { try manager.createDirectory(at: root, withIntermediateDirectories: true) }
                    for name in names {
                        _ = try url(name)
                        let source = retired.appendingPathComponent(name)
                        if manager.fileExists(atPath: source.path) {
                            try manager.moveItem(at: source, to: root.appendingPathComponent(name)); moved.append(name)
                        }
                    }
                    try manager.moveItem(at: retired, to: ready)
                } catch {
                    for name in moved.reversed() {
                        try? manager.moveItem(at: root.appendingPathComponent(name), to: retired.appendingPathComponent(name))
                    }
                    if (try? manager.contentsOfDirectory(atPath: root.path).isEmpty) == true { try? manager.removeItem(at: root) }
                    if !manager.fileExists(atPath: root.path) { try? manager.moveItem(at: retired, to: root) }
                    throw error
                }
            }
            return Self.retiredRoots(root: root, manager: manager, includeUnprepared: false)
        }
        // FileManager performs independent path operations; detached deletion owns only the
        // captured retired trees, while the main actor alone mutates the live root registry.
        let access = MediaCacheFileAccess(manager: manager)
        try await Task.detached(priority: .utility) {
            for directory in pending {
                do { try access.manager.removeItem(at: directory) }
                catch let error as CocoaError where error.code == .fileNoSuchFile { continue }
            }
        }.value
    }

    public func totalByteCount() async -> UInt64 {
        let root = root, manager = manager
        let access = MediaCacheFileAccess(manager: manager)
        return await Task.detached(priority: .utility) { Self.totalBytes(root: root, manager: access.manager) }.value
    }

    private nonisolated static func totalBytes(root: URL, manager: FileManager) -> UInt64 {
        var total: UInt64 = 0
        for directory in [root] + retiredRoots(root: root, manager: manager, includeUnprepared: true) {
            guard let files = manager.enumerator(at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { continue }
            for case let file as URL in files {
                if Task.isCancelled { return total }
                let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if info?.isDirectory != true { total += UInt64(max(0, info?.fileSize ?? 0)) }
            }
        }
        return total
    }

    private nonisolated static func retiredRoots(root: URL, manager: FileManager, includeUnprepared: Bool) -> [URL] {
        ((try? manager.contentsOfDirectory(at: root.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
            .filter { isRetirementName($0.lastPathComponent, prefix: ".clearing-" + root.lastPathComponent + "-")
                || (includeUnprepared && isRetirementName($0.lastPathComponent, prefix: ".retiring-" + root.lastPathComponent + "-")) }
    }
    private nonisolated static func isRetirementName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        guard let id = UUID(uuidString: suffix) else { return false }
        // The whole suffix must be one canonical UUID, never another root's name or extra text.
        return id.uuidString.caseInsensitiveCompare(suffix) == .orderedSame
    }
}

/// Immutable access to Foundation's thread-safe path operations. No delegate or configuration
/// mutation is performed after construction; transfer/root authority stays in MediaCacheWrites.
private struct MediaCacheFileAccess: @unchecked Sendable { let manager: FileManager }

private final class MediaCacheWrites: @unchecked Sendable {
    struct Resource { let handle: FileHandle; let temporary: URL }
    private let lock = NSLock()
    var generation: UInt64 = 0
    var current: [String: UUID] = [:]
    var resources: [UUID: Resource] = [:]
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body()
    }
}

/// One root-generation/destination write lease. Supersession and Clear fence writes and commit;
/// abort removes only this lease's unique staging path, never a successor destination.
public final class MonitorMediaCacheWrite: MediaByteSink, @unchecked Sendable {
    private let id: UUID, generation: UInt64
    private let destination: URL, temporary: URL
    private let handle: FileHandle, writes: MediaCacheWrites, manager: FileManager
    private var bytes: UInt64 = 0
    private var finished = false
    fileprivate init(id: UUID, generation: UInt64, destination: URL, temporary: URL,
        handle: FileHandle, writes: MediaCacheWrites, manager: FileManager) {
        self.id = id; self.generation = generation; self.destination = destination
        self.temporary = temporary; self.handle = handle; self.writes = writes; self.manager = manager
    }
    private func check() throws {
        guard !finished, writes.generation == generation, writes.current[destination.path] == id else {
            throw MonitorMediaCacheError.retired
        }
    }
    public func write(_ chunk: Data) async throws {
        try Task.checkCancellation()
        try writes.withLock { try check(); try handle.write(contentsOf: chunk); bytes += UInt64(chunk.count) }
    }
    public func commit(_ receipt: MediaTransferReceipt) throws -> URL {
        try Task.checkCancellation()
        return try writes.withLock {
            try check()
            guard bytes > 0 else { throw MonitorMediaCacheError.empty }
            guard bytes == receipt.byteCount else { throw MonitorMediaCacheError.invalidReceipt }
            try handle.close()
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.moveItem(at: temporary, to: destination)
            finished = true; writes.current[destination.path] = nil; writes.resources[id] = nil
            return destination
        }
    }
    public func abort() {
        writes.withLock {
            if finished { return }
            finished = true; try? handle.close(); try? manager.removeItem(at: temporary)
            writes.resources[id] = nil
            if writes.current[destination.path] == id { writes.current[destination.path] = nil }
        }
    }
    deinit { abort() }
}

/// Catalog codec, root lifetime and eligibility are explicit inputs; no namespace or schema defaults.
@MainActor public final class MonitorMediaCache<Payload: Sendable> {
    public let directory: MonitorMediaCacheDirectory
    public let codec: any MonitorMediaCatalogCodec<Payload>
    public let eligibility: MonitorMediaOriginalEligibility
    private let catalogAddress: String
    private let preservedMetadata: [String]
    public init(directory: MonitorMediaCacheDirectory, codec: any MonitorMediaCatalogCodec<Payload>,
        eligibility: MonitorMediaOriginalEligibility, catalogAddress: String, preservedMetadata: [String]) {
        self.directory = directory; self.codec = codec; self.eligibility = eligibility
        self.catalogAddress = catalogAddress; self.preservedMetadata = preservedMetadata
    }
    public func load() -> [MonitorMediaRecord<Payload>] {
        guard let bytes = try? directory.read(catalogAddress) else { return [] }
        return (try? codec.decode(bytes)) ?? []
    }
    public func save(_ records: [MonitorMediaRecord<Payload>]) throws {
        try directory.write(codec.encode(records), at: catalogAddress)
    }
    public func entry(_ record: MonitorMediaRecord<Payload>) -> MonitorMediaCacheEntry {
        var original: URL?, proxy: URL?
        for representation in record.asset.representations {
            guard let address = record.address.representations[representation.id],
                let location = directory.existing(address) else { continue }
            if representation.role == .original {
                if eligibility.accepts(bytes: directory.byteCount(address), expected: representation.byteCount) {
                    original = location
                }
            } else if proxy == nil { proxy = location }
        }
        return .init(originalURL: original, proxyURL: proxy, thumbnailURL: directory.existing(record.address.thumbnail))
    }
    public func clear() async throws { try await directory.clear(preserving: preservedMetadata) }
}
