import Foundation

/// A stored take and its durable completion state; an open file is never shared or deleted.
public struct GyroLogEntry: Identifiable, Sendable {
    /// Immutable take identity and timing context.
    public let descriptor: GyroLogDescriptor
    /// Final health and coverage, absent until the take finishes or recovery completes it.
    public let summary: GyroLogSummary?
    /// True while this store still owns the take's partial file.
    public let active: Bool

    /// Unique take identity.
    public var id: UUID { descriptor.id }
    /// Operator-facing badge for this take.
    public var status: GyroTakeStatus {
        GyroTakeStatus.resolve(descriptor: descriptor, summary: summary, active: active)
    }
    /// True when the finished GCSV can be exported.
    public var canShare: Bool { summary != nil && !active }

    /// Creates one entry; stores build entries from their own durable state.
    public init(descriptor: GyroLogDescriptor, summary: GyroLogSummary?, active: Bool) {
        self.descriptor = descriptor
        self.summary = summary
        self.active = active
    }
}

/// Recovery preserves every available row even when an individual interrupted file cannot finish.
public struct GyroLogRecoveryResult: Sendable {
    /// Every take found in the store directory, newest first.
    public let entries: [GyroLogEntry]
    /// Operator-readable warning when an interrupted file could not be completed.
    public let warning: String?

    /// Creates a recovery result; stores build it after scanning their directory.
    public init(entries: [GyroLogEntry], warning: String?) {
        self.entries = entries
        self.warning = warning
    }
}

/// Serial file ownership; every call is safe to await from any task.
public protocol GyroLogStoring: Sendable {
    /// Loads saved takes and completes interrupted ones where possible.
    func load() async throws -> GyroLogRecoveryResult
    /// Applies ordered file updates and returns the current take list.
    func apply(_ updates: [GyroLogUpdate], at time: Double) async throws -> [GyroLogEntry]
    /// Releases open files, marks them inactive and completes interrupted takes.
    func abort() async -> GyroLogRecoveryResult
    /// Copies the finished files for every id into temporary share folders, in the same order.
    func share(_ ids: [UUID]) async throws -> [URL]
    /// Deletes one inactive take and returns the remaining takes.
    func delete(_ id: UUID) async throws -> [GyroLogEntry]
}

/// A store operation that cannot proceed because a take is open or its file is gone.
public enum GyroStoreError: LocalizedError, Equatable, Sendable {
    /// The take is still recording.
    case active
    /// No stored take or finished file matches the request.
    case missing

    /// Operator-readable explanation of the failure.
    public var errorDescription: String? {
        switch self {
        case .active: "This gyro log is still recording."
        case .missing: "The gyro log could not be found."
        }
    }
}

/// Serial file ownership with a one-second durability cadence and atomic metadata publication.
public actor GyroLogStore: GyroLogStoring {
    private let directory: URL
    private var entries: [GyroLogEntry] = []
    private var handles: [UUID: FileHandle] = [:]
    private var lastSync: Double = 0

    /// Creates a store rooted at a host-provided directory, created on first load.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Loads saved takes and completes interrupted ones where possible.
    public func load() throws -> GyroLogRecoveryResult {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                let descriptor = try? JSONDecoder().decode(
                    GyroLogDescriptor.self,
                    from: Data(contentsOf: folder.appendingPathComponent("descriptor.json"))),
                descriptor.id == id
            else { return nil }
            let summary = try? JSONDecoder().decode(
                GyroLogSummary.self,
                from: Data(contentsOf: folder.appendingPathComponent("summary.json")))
            return GyroLogEntry(
                descriptor: descriptor, summary: summary, active: handles[id] != nil)
        }
        let warning = recoverInterruptedLogs()
        return GyroLogRecoveryResult(entries: sortedEntries, warning: warning)
    }

    /// Applies ordered file updates and returns the current take list.
    public func apply(_ updates: [GyroLogUpdate], at time: Double) throws -> [GyroLogEntry] {
        for update in updates {
            switch update {
            case .opened(let descriptor):
                let folder = folder(descriptor.id)
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true)
                try JSONEncoder().encode(descriptor).write(
                    to: folder.appendingPathComponent("descriptor.json"), options: .atomic)
                let file = partial(descriptor.id)
                try Data().write(to: file, options: .withoutOverwriting)
                handles[descriptor.id] = try FileHandle(forWritingTo: file)
                entries.append(GyroLogEntry(descriptor: descriptor, summary: nil, active: true))
            case .appended(let id, let data):
                guard let handle = handles[id] else { throw GyroStoreError.missing }
                try handle.write(contentsOf: data)
            case .mountMoved(let id, let offsetSeconds):
                guard FileManager.default.fileExists(atPath: folder(id).path) else {
                    throw GyroStoreError.missing
                }
                try JSONEncoder().encode(MountMovedMark(offsetSeconds: offsetSeconds)).write(
                    to: mountMovedURL(id), options: .atomic)
            case .finished(let summary):
                try complete(summary)
            }
        }
        if time - lastSync >= 1 {
            for handle in handles.values { try handle.synchronize() }
            lastSync = time
        }
        return sortedEntries
    }

    /// Releases open files, marks them inactive and completes interrupted takes.
    public func abort() -> GyroLogRecoveryResult {
        for handle in handles.values {
            try? handle.synchronize()
            try? handle.close()
        }
        handles.removeAll()
        entries = entries.map {
            GyroLogEntry(descriptor: $0.descriptor, summary: $0.summary, active: false)
        }
        let warning = recoverInterruptedLogs()
        return GyroLogRecoveryResult(entries: sortedEntries, warning: warning)
    }

    /// Copies the finished files for every id into temporary share folders, in the same order.
    public func share(_ ids: [UUID]) throws -> [URL] {
        var sources: [(id: UUID, source: URL, filename: String)] = []
        // Validate the whole batch first so a refused request never leaves a partial share.
        for id in ids {
            guard let entry = entries.first(where: { $0.id == id }) else {
                throw GyroStoreError.missing
            }
            guard !entry.active else { throw GyroStoreError.active }
            guard entry.summary != nil else { throw GyroStoreError.missing }
            let source = finishedURL(entry.descriptor)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw GyroStoreError.missing
            }
            sources.append((id, source, entry.descriptor.filename))
        }
        var urls: [URL] = []
        for item in sources {
            // A stable share copy can outlive deleting the library row while the system sheet
            // is open.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                "GyroShare/\(item.id)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(item.filename)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: item.source, to: target)
            urls.append(target)
        }
        return urls
    }

    /// Deletes one inactive take and returns the remaining takes.
    public func delete(_ id: UUID) throws -> [GyroLogEntry] {
        guard !entries.contains(where: { $0.id == id && $0.active }) else {
            throw GyroStoreError.active
        }
        try FileManager.default.removeItem(at: folder(id))
        entries.removeAll { $0.id == id }
        return sortedEntries
    }

    private var sortedEntries: [GyroLogEntry] {
        entries.sorted { $0.descriptor.startDate > $1.descriptor.startDate }
    }
    private func folder(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    private func partial(_ id: UUID) -> URL {
        folder(id).appendingPathComponent("capture.gcsv.part")
    }
    private func mountMovedURL(_ id: UUID) -> URL {
        folder(id).appendingPathComponent("mount-moved.json")
    }
    private func finishedURL(_ descriptor: GyroLogDescriptor) -> URL {
        folder(descriptor.id).appendingPathComponent(descriptor.filename)
    }
    private func mountMovedOffset(_ id: UUID) -> Double? {
        guard let data = try? Data(contentsOf: mountMovedURL(id)),
            let mark = try? JSONDecoder().decode(MountMovedMark.self, from: data)
        else { return nil }
        return mark.offsetSeconds
    }
    private func complete(_ summary: GyroLogSummary) throws {
        let id = summary.id
        if let handle = handles[id] {
            try handle.synchronize()
            try handle.close()
            handles.removeValue(forKey: id)
        }
        let target = finishedURL(summary.descriptor)
        if FileManager.default.fileExists(atPath: partial(id).path) {
            try FileManager.default.moveItem(at: partial(id), to: target)
        }
        let summary =
            summary.mountMovedOffset == nil
            ? summary.withMountMovedOffset(mountMovedOffset(id)) : summary
        try JSONEncoder().encode(summary).write(
            to: folder(id).appendingPathComponent("summary.json"), options: .atomic)
        entries.removeAll { $0.id == id }
        entries.append(
            GyroLogEntry(descriptor: summary.descriptor, summary: summary, active: false))
    }

    private func recoverInterruptedLogs() -> String? {
        var hadFailure = false
        for entry in entries where entry.summary == nil && !entry.active {
            let source =
                FileManager.default.fileExists(atPath: partial(entry.id).path)
                ? partial(entry.id) : finishedURL(entry.descriptor)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            do { try recover(entry, source: source) } catch {
                // A bad header or a failed write affects this take only. Keep saved logs usable,
                // including deletion to free space when recovery could not publish its metadata.
                hadFailure = true
            }
        }
        return hadFailure
            ? "Some interrupted gyro logs could not be recovered. Saved logs remain available."
            : nil
    }

    private func recover(_ entry: GyroLogEntry, source: URL) throws {
        let handle = try FileHandle(forUpdating: source)
        defer { try? handle.close() }
        var recovery = GyroGCSVRecovery()
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            try recovery.accept(data)
        }
        let summary = try recovery.finish(
            descriptor: entry.descriptor, mountMovedOffset: mountMovedOffset(entry.id))
        try handle.truncate(atOffset: recovery.validByteCount)
        try handle.synchronize()
        try handle.close()
        try complete(summary)
    }
}

/// Atomically published first mount move for one take; read back on completion and recovery.
private struct MountMovedMark: Codable {
    let offsetSeconds: Double
}
