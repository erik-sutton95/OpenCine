import Foundation
import OpenCineMedia

public enum MonitorMediaCacheError: Error, Equatable, Sendable {
    case retired, invalidAddress, empty, invalidReceipt
}

/// Cache addresses are explicit codec inputs, never extracted from an opaque source identity.
public struct MonitorMediaCacheAddress: Equatable, Sendable {
    public let thumbnail: String?
    public let representations: [MediaRepresentationID: String]
    public let favoriteKey: String
    /// Ordered read alternatives. Transfers still write the canonical representation address.
    public let readAlternatives: [MediaRepresentationID: [String]]
    public init(
        thumbnail: String?, representations: [MediaRepresentationID: String], favoriteKey: String,
        readAlternatives: [MediaRepresentationID: [String]] = [:]
    ) {
        self.thumbnail = thumbnail
        self.representations = representations
        self.favoriteKey = favoriteKey
        self.readAlternatives = readAlternatives
    }
}

/// Source authority and local heart policy are explicit values, independent of manufacturer.
public enum MonitorMediaFavoriteAuthority: Equatable, Sendable {
    case legacyCombined, source, localOverlay
}

/// Immutable source or legacy preservation payload. Only the app's codec interprets Payload.
public struct MonitorMediaRecord<Payload: Sendable>: Sendable {
    public let asset: MediaAsset
    public let payload: Payload
    public let address: MonitorMediaCacheAddress
    public var favorite: Bool
    public let facts: MonitorMediaFilterFacts
    public let favoriteAuthority: MonitorMediaFavoriteAuthority
    public let sourceFavorite: Bool?
    public init(
        asset: MediaAsset, payload: Payload, address: MonitorMediaCacheAddress,
        favorite: Bool = false, facts: MonitorMediaFilterFacts = .init(),
        favoriteAuthority: MonitorMediaFavoriteAuthority = .legacyCombined,
        sourceFavorite: Bool? = nil
    ) {
        self.asset = asset
        self.payload = payload
        self.address = address
        self.favorite = favorite
        self.facts = facts
        self.favoriteAuthority = favoriteAuthority
        self.sourceFavorite = sourceFavorite
    }
}

/// An explicit durable catalog namespace. Implementations may retain their original atomic lock.
/// Generation changes retire captured access. Write/update must check admission at commit.
@MainActor public protocol MonitorMediaCatalogByteStore: Sendable {
    var namespace: String { get }
    var generation: UInt64 { get }
    func read() throws -> Data?
    func write(_ bytes: Data, ifCurrent: () -> Bool) throws
    /// A nil result means no durable change; do not rewrite bytes or update registry metadata.
    func update(ifCurrent: () -> Bool, encode: (Data?) throws -> Data?) throws
}
extension MonitorMediaCatalogByteStore {
    public func update(ifCurrent: () -> Bool, encode: (Data?) throws -> Data?) throws {
        guard ifCurrent() else { throw MonitorMediaCacheError.retired }
        let current = try read()
        guard ifCurrent() else { throw MonitorMediaCacheError.retired }
        guard let bytes = try encode(current) else { return }
        guard ifCurrent() else { throw MonitorMediaCacheError.retired }
        try write(bytes, ifCurrent: ifCurrent)
    }
}

@MainActor public protocol MonitorMediaCatalogCodec<Payload>: Sendable {
    associatedtype Payload: Sendable
    func decode(_ bytes: Data) throws -> [MonitorMediaRecord<Payload>]
    func encode(_ records: [MonitorMediaRecord<Payload>]) throws -> Data
    /// Pure preparation against immutable authoritative bytes under the store's update lock.
    /// Nil skips an unchanged checkpoint without an encode/write or registry update.
    func encodeForPersistence(_ records: [MonitorMediaRecord<Payload>], currentBytes: Data?) throws
        -> Data?
    /// Capture immediately after a fenced delta, before encoding/IO can suspend.
    func capture(_ asset: MediaAsset, binding: MediaBrowseBinding) throws -> MonitorMediaRecord<
        Payload
    >
    /// Capture removals and metadata amendments under the producing binding before publication/IO.
    /// Camera observations remain in MediaCatalog; preserved local rows are a separate result.
    func captureCatalog(
        _ delta: MediaCatalogDelta, binding: MediaBrowseBinding,
        existing: [MonitorMediaRecord<Payload>]
    ) throws -> MonitorMediaCatalogCapture<Payload>
    /// Optional exact cache qualification over immutable captured rows. Never query source here.
    func prepareCatalog(
        _ capture: MonitorMediaCatalogCapture<Payload>, binding: MediaBrowseBinding,
        existing: [MonitorMediaRecord<Payload>]
    ) async throws -> MonitorMediaCatalogCapture<Payload>

}

public struct MonitorMediaCatalogCapture<Payload: Sendable>: Sendable {
    public let resetLibrary: Bool
    public let upserts: [MonitorMediaRecord<Payload>]
    public let removed: [MediaAssetID]
    public let amendments: [MonitorMediaRecord<Payload>]
    public let order: [MediaAssetID]?
    /// Nil preserves the current local set; a known set (including empty) is source authority.
    public let sourceFavoriteKeys: Set<String>?
    public init(
        resetLibrary: Bool, upserts: [MonitorMediaRecord<Payload>], removed: [MediaAssetID] = [],
        amendments: [MonitorMediaRecord<Payload>] = [], order: [MediaAssetID]? = nil,
        sourceFavoriteKeys: Set<String>? = nil
    ) {
        self.resetLibrary = resetLibrary
        self.upserts = upserts
        self.removed = removed
        self.amendments = amendments
        self.order = order
        self.sourceFavoriteKeys = sourceFavoriteKeys
    }
}

extension MonitorMediaCatalogCodec {
    public func encodeForPersistence(_ records: [MonitorMediaRecord<Payload>], currentBytes: Data?)
        throws -> Data?
    {
        try encode(records)
    }
    public func prepareCatalog(
        _ capture: MonitorMediaCatalogCapture<Payload>, binding: MediaBrowseBinding,
        existing: [MonitorMediaRecord<Payload>]
    ) async throws -> MonitorMediaCatalogCapture<Payload> { capture }
    public func captureCatalog(
        _ delta: MediaCatalogDelta, binding: MediaBrowseBinding,
        existing: [MonitorMediaRecord<Payload>]
    ) throws -> MonitorMediaCatalogCapture<Payload> {
        .init(
            resetLibrary: delta.reset,
            upserts: try delta.upserts.map { try capture($0, binding: binding) },
            removed: delta.removed)
    }
}

public enum MonitorMediaOriginalEligibility: Equatable, Sendable {
    case exactSize
    case minimumFraction(numerator: UInt64, denominator: UInt64)
    public func accepts(bytes: UInt64, expected: UInt64?) -> Bool {
        guard bytes > 0 else { return false }
        guard let expected, expected > 0 else { return true }
        switch self {
        case .exactSize: return bytes == expected
        case .minimumFraction(let numerator, let denominator):
            guard denominator > 0, numerator <= denominator else { return false }
            let minimum = denominator.dividingFullWidth(expected.multipliedFullWidth(by: numerator))
                .quotient
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

/// A selective clear reports confirmed removals and every selected file that remains retryable.
public struct MonitorMediaCacheRemoval: Equatable, Sendable {
    public let removedBytes: UInt64
    public let remainingFiles: [String]
}

/// Root lifetime shared explicitly by the cache/library owners for that namespace. No globals.
/// One caller-owned declared media root. Gallery and settings reuse each namespace's write lifetime.
@MainActor public final class MonitorMediaCacheRoot {
    public let root: URL
    private let manager: FileManager
    private let accountLegacyUnpreparedRoots: Bool
    private var directories: [String: MonitorMediaCacheDirectory] = [:]
    public init(
        root: URL, fileManager: FileManager = .default, accountLegacyUnpreparedRoots: Bool = false
    ) {
        self.root = root
        manager = fileManager
        self.accountLegacyUnpreparedRoots = accountLegacyUnpreparedRoots
    }
    public func directory(namespace: String) throws -> MonitorMediaCacheDirectory {
        guard !namespace.isEmpty, namespace != ".", namespace != "..", !namespace.contains("/"),
            !namespace.contains("\\")
        else {
            throw MonitorMediaCacheError.invalidAddress
        }
        if let current = directories[namespace] { return current }
        let value = MonitorMediaCacheDirectory(
            root: root.appendingPathComponent(namespace, isDirectory: true),
            fileManager: manager, accountLegacyUnpreparedRoots: accountLegacyUnpreparedRoots)
        directories[namespace] = value
        return value
    }

    /// Every live or valid retired camera namespace on disk, once each in stable order.
    /// Settings can account for interrupted Clear operations and retry prepared deletions.
    public func cachedDirectories() -> [MonitorMediaCacheDirectory] {
        MonitorMediaCacheNamespaces.names(under: root, manager: manager).compactMap {
            try? directory(namespace: $0)
        }
    }

}

@MainActor public final class MonitorMediaCacheDirectory {
    public let root: URL
    fileprivate let manager: FileManager
    private let accountLegacyUnpreparedRoots: Bool
    fileprivate let writes = MediaCacheWrites()
    public var generation: UInt64 { writes.withLock { writes.generation } }
    public init(
        root: URL, fileManager: FileManager = .default, accountLegacyUnpreparedRoots: Bool = false
    ) {
        self.root = root
        manager = fileManager
        self.accountLegacyUnpreparedRoots = accountLegacyUnpreparedRoots
    }

    public func url(_ address: String) throws -> URL {
        let pieces = address.split(separator: "/", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
            !address.contains("\\")
        else { throw MonitorMediaCacheError.invalidAddress }
        return root.appendingPathComponent(address)
    }
    /// Remove only the staging resource supplied by the captured library operation.
    func removeStagingFile(at location: URL) throws { try manager.removeItem(at: location) }
    public func read(_ address: String) throws -> Data { try Data(contentsOf: url(address)) }
    public func write(_ data: Data, at address: String) throws {
        let destination = try url(address)
        var retired: MediaCacheWrites.Resource?
        defer { retired?.requestClose() }
        try writes.withLock {
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let previous = writes.current.removeValue(forKey: destination.path),
                let resource = writes.resources.removeValue(forKey: previous)
            {
                retired = resource
                try? manager.removeItem(at: resource.temporary)
            }
            try data.write(to: destination, options: .atomic)
        }
    }
    public func existing(_ address: String) -> URL? {
        guard let destination = try? url(address),
            let info = try? manager.attributesOfItem(atPath: destination.path),
            info[.type] as? FileAttributeType == .typeRegular,
            (info[.size] as? NSNumber)?.uint64Value ?? 0 > 0
        else { return nil }
        return destination
    }
    public func byteCount(_ address: String) -> UInt64 {
        guard let destination = try? url(address) else { return 0 }
        return ((try? manager.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?
            .uint64Value ?? 0
    }
    public func beginWrite(at address: String) throws -> MonitorMediaCacheWrite {
        try beginWrite(at: address, writeOperation: { try $0.write(contentsOf: $1) })
    }
    // Internal real-I/O seam. Public callers retain the original FileHandle operation.
    func beginWrite(at address: String,
        writeOperation: @escaping @Sendable (FileHandle, Data) throws -> Void
    ) throws -> MonitorMediaCacheWrite {
        let destination = try url(address)
        var retired: MediaCacheWrites.Resource?
        defer { retired?.requestClose() }
        return try writes.withLock {
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let id = UUID()
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(
                id.uuidString + ".part")
            guard manager.createFile(atPath: temporary.path, contents: nil) else {
                throw MonitorMediaCacheError.empty
            }
            let handle = try FileHandle(forWritingTo: temporary)
            if let previous = writes.current[destination.path],
                let resource = writes.resources.removeValue(forKey: previous)
            {
                retired = resource
                try? manager.removeItem(at: resource.temporary)
            }
            let resource = MediaCacheWrites.Resource(handle: handle, temporary: temporary)
            writes.current[destination.path] = id
            writes.resources[id] = resource
            return MonitorMediaCacheWrite(
                id: id, generation: writes.generation, destination: destination,
                resource: resource, writes: writes, manager: manager,
                writeOperation: writeOperation)
        }
    }

    /// Fence old writers and catalog captures while retaining resumable transfer files.
    public func retireWrites() {
        let retired = writes.withLock {
            writes.generation &+= 1
            writes.current.removeAll()
            let resources = Array(writes.resources.values)
            for resource in resources { try? manager.removeItem(at: resource.temporary) }
            writes.resources.removeAll()
            return resources
        }
        for resource in retired { resource.requestClose() }
    }

    /// Invalidate writers and retire the directory before yielding. Deletion sees captured retired
    /// roots only; it never walks a live path created by a later transfer or Clear.
    public func clear(preserving names: [String]) async throws {
        let root = root
        let manager = manager
        var retired: [MediaCacheWrites.Resource] = []
        defer { for resource in retired { resource.requestClose() } }
        let pending: [URL] = try writes.withLock {
            writes.generation &+= 1
            writes.current.removeAll()
            retired = Array(writes.resources.values)
            writes.resources.removeAll()
            // A preserved parent must not carry an active old handle into the new root.
            for resource in retired where manager.fileExists(atPath: resource.temporary.path) {
                try manager.removeItem(at: resource.temporary)
            }
            if MonitorMediaCacheNamespaces.isDirectory(root, manager: manager) {
                let suffix = root.lastPathComponent + "-" + UUID().uuidString
                let retired = root.deletingLastPathComponent().appendingPathComponent(
                    ".retiring-" + suffix)
                let ready = root.deletingLastPathComponent().appendingPathComponent(
                    ".clearing-" + suffix)
                try manager.moveItem(at: root, to: retired)
                var moved: [String] = []
                do {
                    if !names.isEmpty {
                        try manager.createDirectory(at: root, withIntermediateDirectories: true)
                    }
                    for name in names {
                        _ = try url(name)
                        let source = retired.appendingPathComponent(name)
                        if manager.fileExists(atPath: source.path) {
                            try manager.moveItem(at: source, to: root.appendingPathComponent(name))
                            moved.append(name)
                        }
                    }
                    try manager.moveItem(at: retired, to: ready)
                } catch {
                    for name in moved.reversed() {
                        try? manager.moveItem(
                            at: root.appendingPathComponent(name),
                            to: retired.appendingPathComponent(name))
                    }
                    if (try? manager.contentsOfDirectory(atPath: root.path).isEmpty) == true {
                        try? manager.removeItem(at: root)
                    }
                    if !manager.fileExists(atPath: root.path) {
                        try? manager.moveItem(at: retired, to: root)
                    }
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
                do { try access.manager.removeItem(at: directory) } catch let error as CocoaError
                    where error.code == .fileNoSuchFile
                { continue }
            }
        }.value
    }

    public func totalByteCount() async -> UInt64 {
        let root = root
        let manager = manager
        let access = MediaCacheFileAccess(manager: manager)
        let legacy = accountLegacyUnpreparedRoots
        return await Task.detached(priority: .utility) {
            Self.totalBytes(
                root: root, manager: access.manager, accountLegacyUnpreparedRoots: legacy)
        }.value
    }

    /// Counts only the host's declared files, off the main actor. Missing files count as zero;
    /// failed observations throw so Settings can retain an unknown readout.
    public func selectedByteCount(_ addresses: [String]) async throws -> UInt64 {
        try Task.checkCancellation()
        let selected = try selectedFiles(addresses)
        let root = root
        let access = MediaCacheFileAccess(manager: manager)
        let worker = Task.detached(priority: .utility) {
            var bytes: UInt64 = 0
            for address in selected {
                try Task.checkCancellation()
                bytes += try access.selectedFileSize(root: root, address: address) ?? 0
            }
            return bytes
        }
        return try await withTaskCancellationHandler {
            let bytes = try await worker.value
            try Task.checkCancellation()
            return bytes
        } onCancel: {
            worker.cancel()
        }
    }

    /// Retires writers and removes declared files and real descendants of declared directories.
    /// Only empty directories are removed; links, successors and unnamed staging stay intact.
    /// The caller retains its deadline; cancellation stops before the next filesystem mutation.
    public func removeFiles(_ addresses: [String]) throws -> MonitorMediaCacheRemoval {
        try Task.checkCancellation()
        let selected = try selectedFiles(addresses)
        let access = MediaCacheFileAccess(manager: manager)
        let selections = try selected.map { ($0, try access.selectedRemovalFiles(root: root, address: $0)) }
        let paths = try selectedFiles(selections.flatMap { $0.1 })
        let reservations = try Dictionary(uniqueKeysWithValues: paths.map { (try url($0).path, UUID()) })
        // Retire the captured root access, retaining every unnamed staging file. A selective
        // clear cannot infer that an unfinished import is disposable cache.
        let (captured, retired) = try writes.withLock {
            try Task.checkCancellation()
            writes.generation &+= 1
            writes.current.removeAll()
            let resources = Array(writes.resources.values)
            writes.resources.removeAll()
            writes.current.merge(reservations) { _, token in token }
            return (writes.generation, resources)
        }
        defer {
            writes.withLock {
                for (path, token) in reservations where writes.current[path] == token {
                    writes.current[path] = nil
                }
            }
            for resource in retired { resource.requestClose() }
        }
        var bytes: UInt64 = 0
        var remaining: [String] = []
        for (declared, paths) in selections {
            var failed = false
            for address in paths {
                try Task.checkCancellation()
                do {
                    guard let info = try access.selectedItem(root: root, address: address) else { continue }
                    let destination = try url(address)
                    try writes.withLock {
                        guard writes.generation == captured else { throw MonitorMediaCacheError.retired }
                        guard let token = reservations[destination.path], writes.current[destination.path] == token else { return }
                        if info.isDirectory {
                            // rmdir is nonrecursive, so a new or unselected child is never swept away.
                            if rmdir(destination.path) != 0 {
                                let code = errno
                                if code != ENOENT { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
                            }
                        } else {
                            try manager.removeItem(at: destination)
                            bytes += info.size
                        }
                        writes.current[destination.path] = nil
                    }
                } catch MonitorMediaCacheError.retired { throw MonitorMediaCacheError.retired
                } catch let error as CocoaError where MediaCacheFileAccess.isMissing(error) {
                    continue
                } catch { failed = true }
            }
            if failed { remaining.append(declared) }
        }
        return .init(removedBytes: bytes, remainingFiles: remaining)
    }

    private func selectedFiles(_ addresses: [String]) throws -> [String] {
        let selected = Array(Set(addresses)).sorted()
        for address in selected { _ = try url(address) }
        return selected
    }

    private nonisolated static func totalBytes(
        root: URL, manager: FileManager,
        accountLegacyUnpreparedRoots: Bool
    ) -> UInt64 {
        var total: UInt64 = 0
        for directory in [root]
            + retiredRoots(
                root: root, manager: manager, includeUnprepared: true,
                accountLegacyUnpreparedRoots: accountLegacyUnpreparedRoots)
        {
            guard MonitorMediaCacheNamespaces.isDirectory(directory, manager: manager),
                let files = manager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey])
            else { continue }
            for case let file as URL in files {
                if Task.isCancelled { return total }
                let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if info?.isDirectory != true { total += UInt64(max(0, info?.fileSize ?? 0)) }
            }
        }
        return total
    }

    private nonisolated static func retiredRoots(
        root: URL, manager: FileManager, includeUnprepared: Bool,
        accountLegacyUnpreparedRoots: Bool = false
    ) -> [URL] {
        ((try? manager.contentsOfDirectory(
            at: root.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
            .filter {
                // Reject unrelated siblings before asking the filesystem for metadata.
                let owned = isRetirementName(
                    $0.lastPathComponent, prefix: ".clearing-" + root.lastPathComponent + "-")
                    || (includeUnprepared
                        && (isRetirementName(
                            $0.lastPathComponent,
                            prefix: ".retiring-" + root.lastPathComponent + "-")
                            || (accountLegacyUnpreparedRoots
                                && $0.lastPathComponent.hasPrefix(
                                    ".retiring-" + root.lastPathComponent + "-"))))
                return owned && MonitorMediaCacheNamespaces.isDirectory($0, manager: manager)
            }
    }
    private nonisolated static func isRetirementName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        guard let id = UUID(uuidString: suffix) else { return false }
        // The whole suffix must be one canonical UUID, never another root's name or extra text.
        return id.uuidString.caseInsensitiveCompare(suffix) == .orderedSame
    }
}

/// Discover only actual child directories. A retirement encodes its namespace followed by one
/// canonical UUID; malformed or unrelated hidden paths never become cache ownership.
enum MonitorMediaCacheNamespaces {
    static func names(under parent: URL, manager: FileManager) -> [String] {
        let children = (try? manager.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil)) ?? []
        return Set(children.compactMap { child -> String? in
            guard isDirectory(child, manager: manager) else { return nil }
            let name = child.lastPathComponent
            if !name.hasPrefix(".") { return validNamespace(name) ? name : nil }
            for prefix in [".clearing-", ".retiring-"] where name.hasPrefix(prefix) {
                let encoded = String(name.dropFirst(prefix.count))
                guard encoded.count > 37 else { return nil }
                let suffix = String(encoded.suffix(36))
                guard let id = UUID(uuidString: suffix),
                    id.uuidString.caseInsensitiveCompare(suffix) == .orderedSame,
                    encoded.dropLast(36).last == "-"
                else { return nil }
                let namespace = String(encoded.dropLast(37))
                return validNamespace(namespace) ? namespace : nil
            }
            return nil
        }).sorted()
    }

    private static func validNamespace(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\")
    }

    nonisolated static func isDirectory(_ url: URL, manager: FileManager) -> Bool {
        // attributesOfItem inspects the link itself; fileExists(isDirectory:) follows it.
        (try? manager.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType == .typeDirectory
    }
}

/// Immutable access to Foundation's thread-safe path operations. No delegate or configuration
/// mutation is performed after construction; transfer/root authority stays in MediaCacheWrites.
private struct MediaCacheFileAccess: @unchecked Sendable {
    let manager: FileManager

    static func isMissing(_ error: CocoaError) -> Bool {
        error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }

    func selectedFileSize(root: URL, address: String) throws -> UInt64? {
        guard let info = try selectedItem(root: root, address: address) else { return nil }
        guard !info.isDirectory else { throw MonitorMediaCacheError.invalidAddress }
        return info.size
    }

    func selectedRemovalFiles(root: URL, address: String) throws -> [String] {
        try Task.checkCancellation()
        do {
            guard try selectedItem(root: root, address: address)?.isDirectory == true else { return [address] }
            let children = try manager.contentsOfDirectory(atPath: root.appendingPathComponent(address).path)
            return try children.sorted().flatMap { try selectedRemovalFiles(root: root, address: address + "/" + $0) } + [address]
        } catch is CancellationError { throw CancellationError()
        } catch { return [address] }
    }

    func selectedItem(root: URL, address: String) throws -> (isDirectory: Bool, size: UInt64)? {
        do {
            guard
                try manager.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType
                    == .typeDirectory
            else { throw MonitorMediaCacheError.invalidAddress }
            let pieces = address.split(separator: "/")
            var location = root
            for (index, piece) in pieces.enumerated() {
                location.appendPathComponent(String(piece))
                let info = try manager.attributesOfItem(atPath: location.path)
                let last = index == pieces.count - 1
                let type = info[.type] as? FileAttributeType
                guard type == .typeDirectory || (last && type == .typeRegular) else {
                    throw MonitorMediaCacheError.invalidAddress
                }
                if last {
                    if type == .typeDirectory { return (true, 0) }
                    guard let bytes = (info[.size] as? NSNumber)?.uint64Value else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    return (false, bytes)
                }
            }
            throw MonitorMediaCacheError.invalidAddress
        } catch let error as CocoaError where Self.isMissing(error) { return nil }
    }
}

private final class MediaCacheWrites: @unchecked Sendable {
    final class Resource: @unchecked Sendable {
        let handle: FileHandle
        let temporary: URL
        private let io = NSLock()
        private let closing = NSLock()
        private var closeRequested = false
        // Accessed only while io is owned, including the deferred close.
        private var closed = false
        init(handle: FileHandle, temporary: URL) {
            self.handle = handle; self.temporary = temporary
        }
        func withIO<T>(_ body: () throws -> T) rethrows -> T {
            io.lock()
            defer {
                closing.lock()
                if closeRequested {
                    closing.unlock()
                    try? close()
                    io.unlock()
                } else {
                    // Release under closing so a later request cannot miss both owners.
                    io.unlock()
                    closing.unlock()
                }
            }
            return try body()
        }
        func close() throws {
            guard !closed else { return }
            try handle.close()
            closed = true
        }
        func requestClose() {
            closing.lock(); closeRequested = true; closing.unlock()
            Task.detached(priority: .utility) { self.closeIfIdle() }
        }
        private func closeIfIdle() {
            // A busy owner observes closeRequested when it releases I/O. Never wait
            // on a cooperative worker or close concurrently with FileHandle.write.
            guard io.try() else { return }
            defer { io.unlock() }
            try? close()
        }
    }
    private let lock = NSLock()
    var generation: UInt64 = 0
    var current: [String: UUID] = [:]
    var resources: [UUID: Resource] = [:]
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// One root-generation/destination write lease. Supersession and Clear fence writes and commit;
/// abort removes only this lease's unique staging path, never a successor destination.
public final class MonitorMediaCacheWrite: MediaByteSink, @unchecked Sendable {
    private let id: UUID, generation: UInt64
    private let destination: URL
    private let resource: MediaCacheWrites.Resource
    private let writes: MediaCacheWrites, manager: FileManager
    private let writeOperation: @Sendable (FileHandle, Data) throws -> Void
    private var bytes: UInt64 = 0
    private var finished = false
    fileprivate init(
        id: UUID, generation: UInt64, destination: URL, resource: MediaCacheWrites.Resource,
        writes: MediaCacheWrites, manager: FileManager,
        writeOperation: @escaping @Sendable (FileHandle, Data) throws -> Void
    ) {
        self.id = id
        self.generation = generation
        self.destination = destination
        self.resource = resource
        self.writes = writes
        self.manager = manager
        self.writeOperation = writeOperation
    }
    private func check() throws {
        guard !finished, writes.generation == generation, writes.current[destination.path] == id
        else {
            throw MonitorMediaCacheError.retired
        }
    }
    public func write(_ chunk: Data) async throws {
        try Task.checkCancellation()
        try resource.withIO {
            try writes.withLock { try check() }
            try writeOperation(resource.handle, chunk)
            try writes.withLock { try check() }
            bytes += UInt64(chunk.count)
        }
    }
    public func commit(_ receipt: MediaTransferReceipt) throws -> URL {
        try Task.checkCancellation()
        return try resource.withIO {
            try writes.withLock { try check() }
            guard bytes > 0 else { throw MonitorMediaCacheError.empty }
            guard bytes == receipt.byteCount else { throw MonitorMediaCacheError.invalidReceipt }
            try resource.close()
            return try writes.withLock {
                // Close may have blocked while retirement invalidated this lease.
                try check()
                if manager.fileExists(atPath: destination.path) {
                    try manager.removeItem(at: destination)
                }
                try manager.moveItem(at: resource.temporary, to: destination)
                finished = true
                writes.current[destination.path] = nil
                writes.resources[id] = nil
                return destination
            }
        }
    }
    public func abort() {
        let retired: MediaCacheWrites.Resource? = writes.withLock {
            if finished { return nil }
            finished = true
            let owned = writes.resources.removeValue(forKey: id)
            // Clear/supersession already removed this registration. Never use its old
            // URL after the live root may have been replaced by a successor.
            if let owned { try? manager.removeItem(at: owned.temporary) }
            if writes.current[destination.path] == id { writes.current[destination.path] = nil }
            return owned
        }
        retired?.requestClose()
    }
    deinit { abort() }
}

/// Catalog codec, root lifetime and eligibility are explicit inputs; no namespace or schema defaults.
struct MonitorMediaCatalogAuthority: Equatable, Sendable {
    let owner: UUID
    let directoryGeneration: UInt64
    let storeNamespace: String?
    let storeGeneration: UInt64?
}
@MainActor public final class MonitorMediaCache<Payload: Sendable> {
    public let directory: MonitorMediaCacheDirectory
    public let codec: any MonitorMediaCatalogCodec<Payload>
    public let eligibility: MonitorMediaOriginalEligibility
    private let catalogAddress: String
    private let preservedMetadata: [String]
    public let catalogStore: (any MonitorMediaCatalogByteStore)?
    private let catalogOwner = UUID()
    var catalogAuthority: MonitorMediaCatalogAuthority {
        .init(
            owner: catalogOwner, directoryGeneration: directory.generation,
            storeNamespace: catalogStore?.namespace, storeGeneration: catalogStore?.generation)
    }
    func isCurrent(_ authority: MonitorMediaCatalogAuthority) -> Bool {
        catalogAuthority == authority
    }
    private let persistEmptyCatalog: Bool
    public init(
        directory: MonitorMediaCacheDirectory, codec: any MonitorMediaCatalogCodec<Payload>,
        eligibility: MonitorMediaOriginalEligibility, catalogAddress: String,
        preservedMetadata: [String],
        persistEmptyCatalog: Bool = true, catalogStore: (any MonitorMediaCatalogByteStore)? = nil
    ) {
        self.directory = directory
        self.codec = codec
        self.eligibility = eligibility
        self.catalogAddress = catalogAddress
        self.preservedMetadata = preservedMetadata
        self.persistEmptyCatalog = persistEmptyCatalog
        self.catalogStore = catalogStore
    }
    public func load() -> [MonitorMediaRecord<Payload>] {
        if let catalogStore {
            let namespace = catalogStore.namespace
            let generation = catalogStore.generation
            guard let bytes = try? catalogStore.read(), catalogStore.namespace == namespace,
                catalogStore.generation == generation
            else { return [] }
            let records = (try? codec.decode(bytes)) ?? []
            guard catalogStore.namespace == namespace, catalogStore.generation == generation else {
                return []
            }
            return records
        }
        guard let bytes = try? directory.read(catalogAddress) else { return [] }
        return (try? codec.decode(bytes)) ?? []
    }
    public func save(_ records: [MonitorMediaRecord<Payload>], ifCurrent: () -> Bool = { true })
        throws
    {
        guard ifCurrent() else { throw MonitorMediaCacheError.retired }
        guard persistEmptyCatalog || !records.isEmpty else { return }
        let directoryGeneration = directory.generation
        if let catalogStore {
            let namespace = catalogStore.namespace
            let generation = catalogStore.generation
            func admitted() -> Bool {
                ifCurrent() && self.directory.generation == directoryGeneration
                    && catalogStore.namespace == namespace && catalogStore.generation == generation
            }
            try catalogStore.update(ifCurrent: admitted) { currentBytes in
                guard admitted() else { throw MonitorMediaCacheError.retired }
                let bytes = try self.codec.encodeForPersistence(records, currentBytes: currentBytes)
                guard admitted() else { throw MonitorMediaCacheError.retired }
                return bytes
            }
            guard admitted() else { throw MonitorMediaCacheError.retired }
        } else {
            let bytes = try codec.encode(records)
            guard ifCurrent(), directory.generation == directoryGeneration else {
                throw MonitorMediaCacheError.retired
            }
            try directory.write(bytes, at: catalogAddress)
        }
    }
    public func entry(_ record: MonitorMediaRecord<Payload>) -> MonitorMediaCacheEntry {
        var original: URL?
        var proxy: URL?
        for representation in record.asset.representations {
            guard let address = record.address.representations[representation.id] else { continue }
            let candidates = [address] + (record.address.readAlternatives[representation.id] ?? [])
            guard
                let location = candidates.lazy.compactMap({ self.directory.existing($0) }).first(
                    where: {
                        representation.role != .original
                            || eligibility.accepts(
                                bytes: ((try? directory.manager.attributesOfItem(atPath: $0.path)[
                                    .size]) as? NSNumber)?.uint64Value ?? 0,
                                expected: representation.byteCount)
                    })
            else { continue }
            if representation.role == .original {
                if eligibility.accepts(
                    bytes: ((try? directory.manager.attributesOfItem(atPath: location.path)[.size])
                        as? NSNumber)?.uint64Value ?? 0,
                    expected: representation.byteCount)
                {
                    original = location
                }
            } else if proxy == nil {
                proxy = location
            }
        }
        return .init(
            originalURL: original, proxyURL: proxy,
            thumbnailURL: record.address.thumbnail.flatMap { directory.existing($0) })
    }
    /// Captures only immutable paths/size policy on MainActor; read performs actual IO off-main.
    public func readPlan(_ records: [MonitorMediaRecord<Payload>]) -> MonitorMediaCacheReadPlan {
        let entries = records.map { record in
            MediaCacheRecordReadPlan(
                id: record.asset.id,
                thumbnail: record.address.thumbnail.flatMap { try? directory.url($0) },
                representations: record.asset.representations.map { representation in
                    let canonical = record.address.representations[representation.id]
                    let addresses =
                        canonical.map {
                            [$0] + (record.address.readAlternatives[representation.id] ?? [])
                        } ?? []
                    return MediaCacheRepresentationReadPlan(
                        role: representation.role,
                        expected: representation.byteCount,
                        locations: addresses.compactMap { try? directory.url($0) })
                })
        }
        return MonitorMediaCacheReadPlan(
            id: UUID(), generation: directory.generation,
            records: entries, access: .init(manager: directory.manager), eligibility: eligibility)
    }
    public func snapshot(_ records: [MonitorMediaRecord<Payload>]) async throws
        -> MonitorMediaCacheSnapshot
    {
        try await readPlan(records).read()
    }
    public func clear() async throws { try await directory.clear(preserving: preservedMetadata) }

    /// Clear for the settings scope, which removes the camera indexes with the clips (A2-33):
    /// dropping the preserved metadata keeps a formatted card from leaving thumbnail-less ghost
    /// rows behind, and the camera re-enumerates the truth on the next connected pass.
    public func clear(preservingMetadata: Bool) async throws {
        try await directory.clear(preserving: preservingMetadata ? preservedMetadata : [])
    }
}

/// Admission identity accompanies a snapshot; owners reject another plan or retired directory.
public struct MonitorMediaCacheSnapshot: Sendable {
    public let planID: UUID
    public let generation: UInt64
    public let entries: [MediaAssetID: MonitorMediaCacheEntry]
    fileprivate init(
        planID: UUID, generation: UInt64, entries: [MediaAssetID: MonitorMediaCacheEntry]
    ) {
        self.planID = planID
        self.generation = generation
        self.entries = entries
    }
}

private struct MediaCacheRepresentationReadPlan: Sendable {
    let role: MediaRepresentationRole
    let expected: UInt64?
    let locations: [URL]
}
private struct MediaCacheRecordReadPlan: Sendable {
    let id: MediaAssetID
    let thumbnail: URL?
    let representations: [MediaCacheRepresentationReadPlan]
}

/// Immutable facts, no live catalog/codec/actor access in the filesystem worker.
public struct MonitorMediaCacheReadPlan: Sendable {
    public let id: UUID
    public let generation: UInt64
    fileprivate let records: [MediaCacheRecordReadPlan]
    fileprivate let access: MediaCacheFileAccess
    fileprivate let eligibility: MonitorMediaOriginalEligibility

    public func read() async throws -> MonitorMediaCacheSnapshot {
        let id = id
        let generation = generation
        let records = records
        let access = access
        let eligibility = eligibility
        let worker = Task.detached(priority: .utility) {
            func existing(_ location: URL) -> UInt64? {
                guard let facts = try? access.manager.attributesOfItem(atPath: location.path),
                    facts[.type] as? FileAttributeType == .typeRegular,
                    let size = (facts[.size] as? NSNumber)?.uint64Value, size > 0
                else { return nil }
                return size
            }
            var entries: [MediaAssetID: MonitorMediaCacheEntry] = [:]
            for record in records {
                try Task.checkCancellation()
                var original: URL?
                var proxy: URL?
                for representation in record.representations {
                    for location in representation.locations {
                        try Task.checkCancellation()
                        guard let size = existing(location) else { continue }
                        if representation.role == .original {
                            if eligibility.accepts(bytes: size, expected: representation.expected) {
                                original = location
                                break
                            }
                        } else if proxy == nil {
                            proxy = location
                            break
                        }
                    }
                }
                let thumbnail = record.thumbnail.flatMap { existing($0) == nil ? nil : $0 }
                entries[record.id] = .init(
                    originalURL: original, proxyURL: proxy, thumbnailURL: thumbnail)
            }
            try Task.checkCancellation()
            return MonitorMediaCacheSnapshot(planID: id, generation: generation, entries: entries)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
