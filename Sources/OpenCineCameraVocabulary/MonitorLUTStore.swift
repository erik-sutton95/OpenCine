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
                rawValue: UInt8(truncatingIfNeeded: storage.integer(forKey: lastMonitorColorModeKey)))
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

/// Caps on one archive import, so a malformed or hostile pack (many entries, a zip bomb) cannot
/// fill the app container. A `.cube` is tens of KB to a few MB.
public struct CustomLUTArchiveLimits: Sendable, Equatable {
    public var maxEntryBytes: UInt64
    public var maxTotalBytes: UInt64
    public var maxFiles: Int

    public init(
        maxEntryBytes: UInt64 = 64 << 20, maxTotalBytes: UInt64 = 512 << 20, maxFiles: Int = 512
    ) {
        self.maxEntryBytes = maxEntryBytes
        self.maxTotalBytes = maxTotalBytes
        self.maxFiles = maxFiles
    }
}

/// On-disk custom slots: one `.cube` for Rec.709/HLG, D-Log, and D-Log2, plus imported files.
/// Named libraries (a vendor download beside the imports) are stores in folders under `root`.
public final class CustomLUTStore: @unchecked Sendable {
    public let root: URL
    private let preferences: LUTPreferences
    private let lock = NSLock()
    private var cubeCache: [String: CubeLUT] = [:]
    /// Parse order, oldest first. A 33-point cube is about 0.5 MB, so an operator auditioning a
    /// downloaded library keeps only the latest few.
    private var cacheOrder: [String] = []
    private var libraries: [String: CustomLUTStore] = [:]
    static let cachedCubeLimit = 8

    public init(root: URL, preferences: LUTPreferences) {
        self.root = root
        self.preferences = preferences
    }

    /// The store for one named library in `<root>/<name>`, created once and kept, so its parsed
    /// cubes stay cached. Nil for a name that is not a single safe folder name.
    public func library(_ name: String) -> CustomLUTStore? {
        guard CustomLUTIndex.isSafeFileName(name) else { return nil }
        return lock.withLock {
            if let library = libraries[name] { return library }
            let library = CustomLUTStore(
                root: root.appendingPathComponent(name, isDirectory: true), preferences: preferences)
            libraries[name] = library
            return library
        }
    }

    public func list() -> [StoredCustomLUT] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return CustomLUTIndex.stored(fromFileNames: names)
    }

    public func fileName(for slot: CustomLUTSlot) -> String? {
        preferences.customFileName(for: slot)
    }

    public func hasCube(_ slot: CustomLUTSlot) -> Bool {
        guard let name = fileName(for: slot), CustomLUTIndex.isSafeFileName(name) else {
            return false
        }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
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
        let fileName = source.lastPathComponent
        guard CustomLUTIndex.isSafeFileName(fileName) else {
            throw CustomLUTStoreError.invalidFileName
        }
        let text: String
        do {
            text = try String(contentsOf: source, encoding: .utf8)
        } catch {
            throw CustomLUTStoreError.unreadable
        }
        let parsed = try CubeLUT.parse(text)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        cache(parsed, for: fileName)
        return StoredCustomLUT(fileName: fileName)
    }

    @discardableResult
    public func importFile(from source: URL, into slot: CustomLUTSlot) throws -> StoredCustomLUT {
        let previous = fileName(for: slot)
        let stored = try importFile(from: source)
        preferences.setCustomFileName(stored.fileName, for: slot)
        if let previous, previous != stored.fileName, !isShared(previous, excluding: slot) {
            try? remove(StoredCustomLUT(fileName: previous))
        }
        return stored
    }

    /// Imports file-backed entries with actual-size validation and atomic replacement.
    /// Streaming readers should use the `read` overload to refuse excess bytes before writing.
    @discardableResult
    public func importArchive<Entry>(
        _ entries: some Sequence<Entry>, path: (Entry) -> String, size: (Entry) -> UInt64,
        limits: CustomLUTArchiveLimits = .init(), extract: (Entry, URL) throws -> Void
    ) throws -> [StoredCustomLUT] {
        try importArchiveFiles(entries, path: path, size: size, limits: limits) { entry, temporary, budget in
            try extract(entry, temporary)
            let facts = try temporary.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard facts.isRegularFile == true, let count = facts.fileSize, count >= 0,
                UInt64(count) <= budget else { throw CustomLUTStoreError.archiveLimitExceeded }
            return UInt64(count)
        }
    }

    /// Streams archive data into bounded temporary files, then replaces each admitted entry.
    /// The reader must propagate a consumer error; header sizes never authorize extra output.
    @discardableResult
    public func importArchive<Entry>(
        _ entries: some Sequence<Entry>, path: (Entry) -> String, size: (Entry) -> UInt64,
        limits: CustomLUTArchiveLimits = .init(),
        read: (Entry, (Data) throws -> Void) throws -> Void
    ) throws -> [StoredCustomLUT] {
        try importArchiveFiles(entries, path: path, size: size, limits: limits) { entry, temporary, budget in
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
                throw CustomLUTStoreError.unreadable
            }
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            var written: UInt64 = 0
            try read(entry) { data in
                let count = UInt64(data.count)
                guard count <= budget - written else { throw CustomLUTStoreError.archiveLimitExceeded }
                try handle.write(contentsOf: data)
                written += count
            }
            try handle.close()
            return written
        }
    }

    private func importArchiveFiles<Entry>(
        _ entries: some Sequence<Entry>, path: (Entry) -> String, size: (Entry) -> UInt64,
        limits: CustomLUTArchiveLimits, write: (Entry, URL, UInt64) throws -> UInt64
    ) throws -> [StoredCustomLUT] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var extractedBytes: UInt64 = 0
        var extractedFiles = 0
        for entry in entries {
            guard extractedFiles < limits.maxFiles else { break }
            let fileName = (path(entry) as NSString).lastPathComponent
            let declared = size(entry)
            let budget = min(limits.maxEntryBytes, limits.maxTotalBytes - extractedBytes)
            guard fileName.lowercased().hasSuffix(".cube"), CustomLUTIndex.isSafeFileName(fileName),
                declared <= budget else { continue }
            let temporary = root.appendingPathComponent(".import-" + UUID().uuidString + ".tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let written = try write(entry, temporary, budget)
            guard written <= budget else { throw CustomLUTStoreError.archiveLimitExceeded }
            let destination = root.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            cache(nil, for: fileName)
            extractedBytes += max(declared, written)
            extractedFiles += 1
        }
        return list()
    }

    public func cube(_ lut: StoredCustomLUT) -> CubeLUT? {
        cube(fileName: lut.fileName)
    }

    public func cube(fileName: String) -> CubeLUT? {
        guard CustomLUTIndex.isSafeFileName(fileName) else { return nil }
        if let cached = lock.withLock({ cubeCache[fileName] }) { return cached }
        let url = root.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
            let parsed = try? CubeLUT.parse(text)
        else { return nil }
        cache(parsed, for: fileName)
        return parsed
    }

    public func remove(_ lut: StoredCustomLUT) throws {
        guard CustomLUTIndex.isSafeFileName(lut.fileName) else {
            throw CustomLUTStoreError.invalidFileName
        }
        do {
            try FileManager.default.removeItem(at: root.appendingPathComponent(lut.fileName))
            cache(nil, for: lut.fileName)
        } catch {
            throw CustomLUTStoreError.deletionFailed(lut.displayName)
        }
    }

    public func clear(_ slot: CustomLUTSlot) throws {
        let name = fileName(for: slot)
        preferences.setCustomFileName(nil, for: slot)
        if let name, !isShared(name, excluding: slot) {
            try remove(StoredCustomLUT(fileName: name))
        }
    }

    private func isShared(_ fileName: String, excluding slot: CustomLUTSlot) -> Bool {
        slot.others.contains { preferences.customFileName(for: $0) == fileName }
    }

    // ponytail: first in, first out; least recently used if auditioning a library thrashes.
    private func cache(_ cube: CubeLUT?, for fileName: String) {
        lock.withLock {
            cacheOrder.removeAll { $0 == fileName }
            cubeCache[fileName] = cube
            guard cube != nil else { return }
            cacheOrder.append(fileName)
            if cacheOrder.count > Self.cachedCubeLimit {
                cubeCache[cacheOrder.removeFirst()] = nil
            }
        }
    }

    /// Cubes held parsed, for the cache bound's test.
    var cachedCubeCount: Int { lock.withLock { cubeCache.count } }
}

public enum CustomLUTStoreError: LocalizedError {
    case invalidFileName
    case unreadable
    case archiveLimitExceeded
    case deletionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFileName:
            return "The LUT file name is not valid."
        case .archiveLimitExceeded:
            return "The archive exceeds the allowed extracted size."
        case .unreadable:
            return "The .cube file could not be read."
        case .deletionFailed(let name):
            return "The LUT “\(name)” could not be deleted."
        }
    }
}
