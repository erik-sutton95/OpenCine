import Foundation

/// What importing a downloaded LUT pack (a zip, or a lone `.cube`) into one library category did.
/// The Swift twin of the Kotlin `MonitorLutPackImportResult` (camera-controls), same fields.
public struct MonitorLutPackImportResult: Equatable, Sendable {
    public let importedCount: Int
    public let foundCubeEntries: Int
    public let rejectedCubeEntries: Int
    /// The download is neither a `.cube` nor a zip archive.
    public let notAnArchive: Bool
    /// The archive could not be walked; the reader's own words, for the host's copy.
    public let archiveError: String?

    public init(
        importedCount: Int, foundCubeEntries: Int? = nil, rejectedCubeEntries: Int = 0,
        notAnArchive: Bool = false, archiveError: String? = nil
    ) {
        self.importedCount = importedCount
        self.foundCubeEntries = foundCubeEntries ?? importedCount
        self.rejectedCubeEntries = rejectedCubeEntries
        self.notAnArchive = notAnArchive
        self.archiveError = archiveError
    }
}

extension CustomLUTStore {
    /// Imports a downloaded pack into this store (one library category): every `.cube` entry
    /// (nested folders allowed, the `__MACOSX` shadow and `._` forks skipped) up to
    /// `limits.maximumFiles` files of `limits.maximumEntryBytes` each, the same rule as the Kotlin
    /// `MonitorLutLibrary.importPack`. Each cube is validated and installed on its own through
    /// `importArchive`, so a refused cube is counted and never replaces a usable file, while the
    /// pack's other cubes still land.
    ///
    /// ZIP decoding stays with the platform adapter on Apple (OpenCine carries no ZIP library):
    /// `entries` walks the archive and hands each member to `accept`, as for `importArchive`.
    /// It is not called for a lone `.cube` or a file without a ZIP signature.
    public func importPack(
        file: URL, limits: CustomLUTArchiveLimits = .init(),
        entries: (_ accept: (CustomLUTArchiveEntry) throws -> Void) throws -> Void
    ) -> MonitorLutPackImportResult {
        if file.pathExtension.lowercased() == "cube" {
            let ok = (try? importFile(from: file)) != nil
            return MonitorLutPackImportResult(
                importedCount: ok ? 1 : 0, foundCubeEntries: 1, rejectedCubeEntries: ok ? 0 : 1)
        }
        guard file.looksLikeZipArchive else {
            return MonitorLutPackImportResult(importedCount: 0, notAnArchive: true)
        }
        var found = 0
        var imported = 0
        var rejected = 0
        var total = 0
        do {
            try entries { entry in
                guard let path = Self.packCubePath(entry.path) else { return }
                found += 1
                guard found <= limits.maximumFiles else {
                    throw CustomLUTArchiveError.limitExceeded
                }
                // One safe basename per cube, as the Kotlin pack import stages it.
                let named = CustomLUTArchiveEntry(
                    path: sanitizeLutCubeFileName(path), uncompressedSize: entry.uncompressedSize,
                    isSymbolicLink: entry.isSymbolicLink,
                    extract: { consume in
                        try entry.extract { chunk in
                            total += chunk.count
                            try consume(chunk)
                        }
                    })
                let before = total
                let remaining = max(0, limits.maximumTotalBytes - before)
                do {
                    let stored = try importArchive(
                        limits: CustomLUTArchiveLimits(
                            maximumEntryBytes: limits.maximumEntryBytes,
                            maximumTotalBytes: remaining, maximumFiles: 1)
                    ) { accept in try accept(named) }
                    if stored.isEmpty { rejected += 1 } else { imported += 1 }
                } catch CustomLUTArchiveError.limitExceeded {
                    throw CustomLUTArchiveError.limitExceeded
                } catch {
                    rejected += 1
                }
            }
        } catch {
            return MonitorLutPackImportResult(
                importedCount: imported, foundCubeEntries: found, rejectedCubeEntries: rejected,
                archiveError: error.localizedDescription)
        }
        return MonitorLutPackImportResult(
            importedCount: imported, foundCubeEntries: found, rejectedCubeEntries: rejected)
    }

    /// The Kotlin `normalizeZipEntryPath` cube rule: backslashes as folders, leading `/` dropped,
    /// traversal refused, only `.cube` files outside the macOS resource shadow.
    static func packCubePath(_ raw: String) -> String? {
        var path = raw.replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("/") { path.removeFirst() }
        guard !path.isEmpty, path != ".", path != "..",
            !path.split(separator: "/").contains("..")
        else { return nil }
        guard path.lowercased().hasSuffix(".cube") else { return nil }
        let base = path.split(separator: "/").last.map(String.init) ?? path
        if base.hasPrefix("._") || path.lowercased().contains("__macosx/") { return nil }
        return path
    }
}

extension URL {
    /// True when the file starts with a ZIP signature (`PK\x03\x04`, `PK\x05\x06` or `PK\x07\x08`).
    public var looksLikeZipArchive: Bool {
        guard let handle = try? FileHandle(forReadingFrom: self) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let bytes = [UInt8](head)
        guard bytes[0] == 0x50, bytes[1] == 0x4B else { return false }
        return (bytes[2], bytes[3]) == (3, 4) || (bytes[2], bytes[3]) == (5, 6)
            || (bytes[2], bytes[3]) == (7, 8)
    }
}

/// Keeps only a safe basename (letters, digits, `.`, `-`, `_`) ending in `.cube`, at most 180
/// characters.
public func sanitizeLutCubeFileName(_ raw: String) -> String {
    let afterSlash =
        raw.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? raw
    var base =
        afterSlash.split(separator: "\\", omittingEmptySubsequences: false).last.map(String.init)
        ?? afterSlash
    if base.trimmingCharacters(in: .whitespaces).isEmpty { base = "lut.cube" }
    let cleaned = String(
        base.map { ch in
            ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_" ? ch : "_"
        })
    let withExtension = cleaned.lowercased().hasSuffix(".cube") ? cleaned : cleaned + ".cube"
    let clipped = String(withExtension.prefix(180))
    return clipped.trimmingCharacters(in: .whitespaces).isEmpty ? "lut.cube" : clipped
}
