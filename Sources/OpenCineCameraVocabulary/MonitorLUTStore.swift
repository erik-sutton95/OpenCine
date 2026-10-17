import Foundation
import OpenCineMedia

/// Live picture color for LUT, scopes, and exposure tools.
/// Photo / Live Photo is Rec.709 even when `@2` still reports a log SET.
public enum LiveMonitorColorScience {
    public static func colorMode(isPhoto: Bool, colorMode: ColorMode?) -> ColorMode? {
        isPhoto ? .normal : colorMode
    }

    public static func transfer(isPhoto: Bool, colorMode: ColorMode?) -> MonitorTransfer? {
        self.colorMode(isPhoto: isPhoto, colorMode: colorMode).map(MonitorTransfer.init)
    }

    public static func transfer(status: CameraStatus) -> MonitorTransfer? {
        transfer(isPhoto: status.isPhoto, colorMode: status.colorMode)
    }
}

extension LUTSelection {
    /// Official log conversions and log-specific custom slots. Not Creative or generic Custom.
    public var appliesTechnicalLogConversion: Bool {
        switch self {
        case .auto, .officialAuto, .officialDLog, .officialDLog2, .djiDLog, .djiDLog2, .djiDLogM,
            .iLogRec709, .customDLog, .customDLog2:
            true
        default:
            false
        }
    }
}

/// Shell LUT resolve. Forwards to core and suppresses technical log cubes in live Photo.
public enum LiveLUTResolver {
    public static func resolve(
        selection: LUTSelection,
        colorMode: ColorMode?,
        profile: CameraLUTProfile? = nil,
        hasCustomDLog: Bool,
        hasCustomDLog2: Bool,
        hasCustomRec709: Bool = false,
        customFileName: String? = nil,
        isPhoto: Bool = false
    ) -> LUTSource {
        if isPhoto, selection.appliesTechnicalLogConversion { return .off }
        return LUTResolver.resolve(
            selection: selection,
            colorMode: colorMode,
            profile: profile,
            hasCustomDLog: hasCustomDLog,
            hasCustomDLog2: hasCustomDLog2,
            hasCustomRec709: hasCustomRec709,
            customFileName: customFileName)
    }
}

/// The operator's saved LUT choices, under the app's own key names (`<namespace>.LUTSelection`
/// and so on), so selections saved before this owner existed still load.
public final class LUTPreferences: @unchecked Sendable {
    private let storage: UserDefaults
    private let lutKey: String
    private let customLUTKey: String
    private let lutWasCustomKey: String
    private let lutSelectionKey: String
    private let customRec709FileKey: String
    private let customDLogFileKey: String
    private let customDLog2FileKey: String
    private let selectedCustomFileKey: String
    private let lastMonitorColorModeKey: String

    public init(storage: UserDefaults, namespace: String) {
        precondition(!namespace.isEmpty)
        self.storage = storage
        lutKey = "\(namespace).LastLUT"
        customLUTKey = "\(namespace).LastCustomLUT"
        lutWasCustomKey = "\(namespace).LastLUTWasCustom"
        lutSelectionKey = "\(namespace).LUTSelection"
        customRec709FileKey = "\(namespace).CustomRec709File"
        customDLogFileKey = "\(namespace).CustomDLogFile"
        customDLog2FileKey = "\(namespace).CustomDLog2File"
        selectedCustomFileKey = "\(namespace).SelectedCustomLUTFile"
        lastMonitorColorModeKey = "\(namespace).LastMonitorColorMode"
    }

    /// Last live `ColorMode` so Auto LUT can bind a cube from the offline library.
    public var lastMonitorColorMode: ColorMode? {
        get {
            guard storage.object(forKey: lastMonitorColorModeKey) != nil else { return nil }
            return ColorMode(
                rawValue: UInt8(
                    truncatingIfNeeded: storage.integer(forKey: lastMonitorColorModeKey)))
        }
        set {
            if let newValue {
                storage.set(Int(newValue.rawValue), forKey: lastMonitorColorModeKey)
            } else {
                storage.removeObject(forKey: lastMonitorColorModeKey)
            }
        }
    }

    public var lastLUT: String {
        get {
            if lastLUTWasCustom, let file = lastCustomFileName {
                return CustomLUTIndex.displayName(fileName: file)
            }
            return lastBuiltInLUT
        }
        set { storage.set(newValue, forKey: lutKey) }
    }

    public var lastBuiltInLUT: String {
        storage.string(forKey: lutKey) ?? LUTSelection.auto.title
    }

    public var lastCustomFileName: String? {
        get { storage.string(forKey: customLUTKey) }
        set { storage.set(newValue, forKey: customLUTKey) }
    }

    public var lastLUTWasCustom: Bool {
        get { storage.bool(forKey: lutWasCustomKey) }
        set { storage.set(newValue, forKey: lutWasCustomKey) }
    }

    public var lutSelection: LUTSelection {
        get {
            if let raw = storage.string(forKey: lutSelectionKey),
                let value = LUTSelection(rawValue: raw)
            {
                return value
            }
            return .officialAuto
        }
        set { storage.set(newValue.rawValue, forKey: lutSelectionKey) }
    }

    public func customFileName(for slot: CustomLUTSlot) -> String? {
        storage.string(forKey: customFileKey(slot))
    }

    public func setCustomFileName(_ fileName: String?, for slot: CustomLUTSlot) {
        storage.set(fileName, forKey: customFileKey(slot))
    }

    public var selectedCustomFileName: String? {
        get {
            let name = storage.string(forKey: selectedCustomFileKey)
            guard let name, CustomLUTIndex.isSafeFileName(name) else { return nil }
            return name
        }
        set { storage.set(newValue, forKey: selectedCustomFileKey) }
    }

    /// One-shot: old Built-in looks become Auto; a stored custom file becomes Custom D-Log.
    public func migrateLegacySelectionIfNeeded(lutEnabled: Bool) {
        guard storage.object(forKey: lutSelectionKey) == nil else { return }
        if lastLUTWasCustom, let file = lastCustomFileName, CustomLUTIndex.isSafeFileName(file) {
            setCustomFileName(file, for: .dLog)
            if lutEnabled {
                storage.set(LUTSelection.customDLog.rawValue, forKey: lutSelectionKey)
                return
            }
        }
        storage.set(LUTSelection.officialAuto.rawValue, forKey: lutSelectionKey)
    }

    private func customFileKey(_ slot: CustomLUTSlot) -> String {
        switch slot {
        case .rec709: customRec709FileKey
        case .dLog: customDLogFileKey
        case .dLog2: customDLog2FileKey
        }
    }
}

/// On-disk custom slots: one `.cube` for Rec.709/HLG, D-Log, and D-Log2, plus imported files.
public final class CustomLUTStore: @unchecked Sendable {
    public let root: URL
    private let preferences: LUTPreferences
    private let lock = NSLock()
    private struct FileIdentity: Equatable {
        let device: UInt64
        let file: UInt64
        let size: UInt64
        let modified: Date
    }

    private struct CachedCube {
        let identity: FileIdentity
        let cube: CubeLUT
    }

    private var cubeCache: [String: CachedCube] = [:]
    private var categoryStores: [String: CustomLUTStore] = [:]
    private let fileAccessLock = NSRecursiveLock()
    private let atomicWrite: (Data, URL) throws -> Void

    public init(root: URL, preferences: LUTPreferences) {
        self.root = root
        self.preferences = preferences
        atomicWrite = { try $0.write(to: $1, options: .atomic) }
    }

    /// Internal filesystem seam for controlled transaction-failure tests.
    init(
        root: URL, preferences: LUTPreferences,
        atomicWrite: @escaping (Data, URL) throws -> Void
    ) {
        self.root = root
        self.preferences = preferences
        self.atomicWrite = atomicWrite
    }

    public func list() -> [StoredCustomLUT] {
        guard !Self.isSymbolicLink(root) else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return CustomLUTIndex.stored(
            fromFileNames: names.filter { name in
                guard let url = try? storedURL(name) else { return false }
                return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            })
    }

    public func fileName(for slot: CustomLUTSlot) -> String? {
        preferences.customFileName(for: slot)
    }

    public func hasCube(_ slot: CustomLUTSlot) -> Bool {
        guard let name = fileName(for: slot), CustomLUTIndex.isSafeFileName(name) else {
            return false
        }
        guard let url = try? storedURL(name) else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    public func displayName(for slot: CustomLUTSlot) -> String? {
        guard let name = fileName(for: slot), hasCube(slot) else { return nil }
        return CustomLUTIndex.displayName(fileName: name)
    }

    public func cube(_ slot: CustomLUTSlot) -> CubeLUT? {
        guard let name = fileName(for: slot) else { return nil }
        return cube(fileName: name)
    }

    @discardableResult
    public func importFile(from source: URL) throws -> StoredCustomLUT {
        try fileAccessLock.withLock {
            let fileName = source.lastPathComponent
            let destination = try storedURL(fileName)
            guard !Self.isSymbolicLink(source) else { throw CustomLUTStoreError.invalidFileName }
            let data = try Self.readBounded(source)
            _ = try Self.parse(data)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            // Preserve the usable destination through validation and the complete atomic write.
            try atomicWrite(data, destination)
            cache(nil, for: fileName)
            return StoredCustomLUT(fileName: fileName)
        }
    }

    @discardableResult
    public func importFile(from source: URL, into slot: CustomLUTSlot) throws -> StoredCustomLUT {
        try fileAccessLock.withLock {
            let previous = fileName(for: slot)
            let stored = try importFile(from: source)
            preferences.setCustomFileName(stored.fileName, for: slot)
            if let previous, previous != stored.fileName, !isShared(previous, excluding: slot) {
                try? remove(StoredCustomLUT(fileName: previous))
            }
            return stored
        }
    }

    public func cube(_ lut: StoredCustomLUT) -> CubeLUT? {
        cube(fileName: lut.fileName)
    }

    public func cube(fileName: String) -> CubeLUT? {
        fileAccessLock.withLock {
            guard let url = try? storedURL(fileName) else { return nil }
            let before = Self.fileIdentity(url)
            if let before, let cached = lock.withLock({ cubeCache[fileName] }),
                cached.identity == before
            {
                return cached.cube
            }
            cache(nil, for: fileName)
            guard let data = try? Self.readBounded(url), let parsed = try? Self.parse(data)
            else { return nil }
            let after = Self.fileIdentity(url)
            guard before == after else { return nil }
            // Independent stores and external atomic replacements have a new file identity,
            // even when the name, length and modification date are unchanged. Unknown metadata
            // permits a bounded read but never reuses a parsed cache entry.
            if let after { cache(CachedCube(identity: after, cube: parsed), for: fileName) }
            return parsed
        }
    }

    public func remove(_ lut: StoredCustomLUT) throws {
        try fileAccessLock.withLock {
            let destination = try storedURL(lut.fileName)
            do {
                try FileManager.default.removeItem(at: destination)
                cache(nil, for: lut.fileName)
            } catch {
                throw CustomLUTStoreError.deletionFailed(lut.displayName)
            }
        }
    }

    public func clear(_ slot: CustomLUTSlot) throws {
        try fileAccessLock.withLock {
            let name = fileName(for: slot)
            preferences.setCustomFileName(nil, for: slot)
            if let name, !isShared(name, excluding: slot) {
                try remove(StoredCustomLUT(fileName: name))
            }
        }
    }

    private func isShared(_ fileName: String, excluding slot: CustomLUTSlot) -> Bool {
        slot.others.contains { preferences.customFileName(for: $0) == fileName }
    }

    private static func fileIdentity(_ url: URL) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let device = attributes[.systemNumber] as? NSNumber,
            let file = attributes[.systemFileNumber] as? NSNumber,
            let size = attributes[.size] as? NSNumber,
            let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return FileIdentity(
            device: device.uint64Value, file: file.uint64Value,
            size: size.uint64Value, modified: modified)
    }

    private func cache(_ cube: CachedCube?, for fileName: String) {
        lock.withLock { cubeCache[fileName] = cube }
    }
}

/// Actual output limits for one archive import, independent of its advertised ZIP sizes.
public struct CustomLUTArchiveLimits: Sendable {
    public let maximumEntryBytes: Int
    public let maximumTotalBytes: Int
    public let maximumFiles: Int

    public init(
        maximumEntryBytes: Int = CubeLUT.maximumImportBytes,
        maximumTotalBytes: Int = 512 * 1024 * 1024, maximumFiles: Int = 512
    ) {
        self.maximumEntryBytes = maximumEntryBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumFiles = maximumFiles
    }
}

/// One decoder-owned archive member. Extraction is synchronous and streams bounded chunks.
/// Platform adapters retain ZIP parsing and must throw on checksum or decoder failure.
public struct CustomLUTArchiveEntry {
    public let path: String
    public let uncompressedSize: UInt64?
    public let isSymbolicLink: Bool
    let extract: (_ consume: (Data) throws -> Void) throws -> Void

    public init(
        path: String, uncompressedSize: UInt64? = nil, isSymbolicLink: Bool = false,
        extract: @escaping (_ consume: (Data) throws -> Void) throws -> Void
    ) {
        self.path = path
        self.uncompressedSize = uncompressedSize
        self.isSymbolicLink = isSymbolicLink
        self.extract = extract
    }
}

/// Category and archive failures, additive to the published single-file error contract.
public enum CustomLUTArchiveError: LocalizedError, Equatable {
    case invalidCategory
    case invalidEntry
    case limitExceeded
    case duplicateFileName
    case truncatedEntry
    case recoveryRequired(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidCategory: "The LUT library category is not valid."
        case .invalidEntry: "The archive contains an unsafe LUT entry."
        case .limitExceeded: "The LUT archive exceeds the import limits."
        case .duplicateFileName: "The archive contains duplicate LUT file names."
        case .truncatedEntry: "A LUT archive entry is incomplete."
        case .recoveryRequired:
            "The import could not finish. Previous LUT files were retained for recovery."
        }
    }
}

extension CustomLUTStore {
    /// A stable store for one safe subdirectory. Existing root-level slots and names are unchanged.
    public func category(named name: String) throws -> CustomLUTStore {
        guard Self.safeComponent(name), !Self.isSymbolicLink(root) else {
            throw CustomLUTArchiveError.invalidCategory
        }
        let directory = root.appendingPathComponent(name, isDirectory: true)
        guard !Self.isSymbolicLink(directory) else { throw CustomLUTArchiveError.invalidCategory }
        return lock.withLock {
            if let existing = categoryStores[name] { return existing }
            let child = CustomLUTStore(root: directory, preferences: preferences)
            categoryStores[name] = child
            return child
        }
    }

    /// Streams and validates the entire archive before replacing any usable destination. Paths
    /// are flattened to safe basenames; decoder failures, duplicates and limits leave it untouched.
    /// Each installed file is atomic. A filesystem failure rolls back earlier replacements.
    @discardableResult
    public func importArchive(
        limits: CustomLUTArchiveLimits = .init(),
        entries: (_ accept: (CustomLUTArchiveEntry) throws -> Void) throws -> Void
    ) throws -> [StoredCustomLUT] {
        try fileAccessLock.withLock {
            guard limits.maximumEntryBytes >= 0, limits.maximumTotalBytes >= 0,
                limits.maximumFiles >= 0
            else { throw CustomLUTArchiveError.limitExceeded }
            guard !Self.isSymbolicLink(root) else { throw CustomLUTArchiveError.invalidEntry }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let staging = root.appendingPathComponent(
                ".lut-import-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            var removeStaging = true
            defer { if removeStaging { try? FileManager.default.removeItem(at: staging) } }
            var staged: [(name: String, url: URL)] = []
            var names = Set<String>()
            var total = 0
            try entries { entry in
                guard let name = try Self.archiveFileName(entry.path) else { return }
                guard !entry.isSymbolicLink else { throw CustomLUTArchiveError.invalidEntry }
                _ = try storedURL(name)
                let key = name.precomposedStringWithCanonicalMapping.lowercased()
                guard names.insert(key).inserted else {
                    throw CustomLUTArchiveError.duplicateFileName
                }
                guard staged.count < limits.maximumFiles else {
                    throw CustomLUTArchiveError.limitExceeded
                }
                if let declared = entry.uncompressedSize {
                    guard declared <= UInt64(limits.maximumEntryBytes),
                        declared <= UInt64(limits.maximumTotalBytes - total)
                    else { throw CustomLUTArchiveError.limitExceeded }
                }
                let target = staging.appendingPathComponent("entry-\(staged.count).cube")
                guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
                    throw CustomLUTStoreError.unreadable
                }
                let output = try FileHandle(forWritingTo: target)
                var count = 0
                do {
                    try entry.extract { chunk in
                        guard chunk.count <= limits.maximumEntryBytes - count,
                            chunk.count <= limits.maximumTotalBytes - total
                        else { throw CustomLUTArchiveError.limitExceeded }
                        try output.write(contentsOf: chunk)
                        count += chunk.count
                        total += chunk.count
                    }
                    try output.close()
                } catch {
                    try? output.close()
                    throw error
                }
                if let declared = entry.uncompressedSize, declared != UInt64(count) {
                    throw CustomLUTArchiveError.truncatedEntry
                }
                _ = try Self.parse(Self.readBounded(target))
                staged.append((name, target))
            }
            guard !staged.isEmpty else { return [] }
            // All validation succeeded. Keep on-disk backups until the last atomic installation.
            var backups: [String: URL] = [:]
            for (index, item) in staged.enumerated() {
                let destination = try storedURL(item.name)
                if FileManager.default.fileExists(atPath: destination.path) {
                    let backup = staging.appendingPathComponent("backup-\(index)")
                    try FileManager.default.copyItem(at: destination, to: backup)
                    backups[item.name] = backup
                }
            }
            var installed: [String] = []
            do {
                for item in staged {
                    let destination = try storedURL(item.name)
                    try atomicWrite(Data(contentsOf: item.url), destination)
                    installed.append(item.name)
                }
            } catch {
                for name in installed.reversed() {
                    let destination = root.appendingPathComponent(name)
                    do {
                        if let backup = backups[name] {
                            try atomicWrite(Data(contentsOf: backup), destination)
                        } else {
                            try FileManager.default.removeItem(at: destination)
                        }
                    } catch { removeStaging = false }
                }
                if !removeStaging { throw CustomLUTArchiveError.recoveryRequired(staging) }
                throw error
            }
            for item in staged { cache(nil, for: item.name) }
            return list()
        }
    }

    private static func safeComponent(_ name: String) -> Bool {
        CustomLUTIndex.isSafeFileName(name) && name != "." && name != ".." && !name.contains("\0")
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func storedURL(_ name: String) throws -> URL {
        guard Self.safeComponent(name), !Self.isSymbolicLink(root) else {
            throw CustomLUTStoreError.invalidFileName
        }
        let url = root.appendingPathComponent(name)
        guard !Self.isSymbolicLink(url) else { throw CustomLUTStoreError.invalidFileName }
        return url
    }

    private static func parse(_ bytes: Data) throws -> CubeLUT {
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw CustomLUTStoreError.unreadable
        }
        return try CubeLUT.parse(text)
    }

    private static func readBounded(_ url: URL) throws -> Data {
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: url) } catch {
            throw CustomLUTStoreError.unreadable
        }
        defer { try? input.close() }
        var bytes = Data()
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard chunk.count <= CubeLUT.maximumImportBytes - bytes.count else {
                throw CustomLUTArchiveError.limitExceeded
            }
            bytes.append(chunk)
        }
        return bytes
    }

    private static func archiveFileName(_ raw: String) throws -> String? {
        let path = raw.replacingOccurrences(of: "\\", with: "/")
        guard path.lowercased().hasSuffix(".cube") else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard !components.contains(where: { $0 == ".." || $0.contains("\0") || $0.contains(":") }),
            let name = components.last, safeComponent(name)
        else { throw CustomLUTArchiveError.invalidEntry }
        if components.contains(where: { $0.lowercased() == "__macosx" }) || name.hasPrefix("._") {
            return nil
        }
        return name
    }
}

public enum CustomLUTStoreError: LocalizedError {
    case invalidFileName
    case unreadable
    case deletionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFileName:
            return "The LUT file name is not valid."
        case .unreadable:
            return "The .cube file could not be read."
        case .deletionFailed(let name):
            return "The LUT “\(name)” could not be deleted."
        }
    }
}
