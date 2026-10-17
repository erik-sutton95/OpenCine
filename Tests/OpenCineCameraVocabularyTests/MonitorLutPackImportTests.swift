import Foundation
import OpenCineMedia
import Testing

@testable import OpenCineCameraVocabulary

/// Twin of the Kotlin `MonitorLutPackImportTest`: a downloaded pack lands in one library category
/// through the store's own validation gate. ZIP decoding is the adapter's, so the entries are
/// handed over as the adapter would after reading a file that carries a ZIP signature.
@Suite struct MonitorLutPackImportTests {
    private let valid = Data(
        "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n".utf8)

    private func withStore(_ body: (CustomLUTStore, URL) throws -> Void) throws {
        let name = "MonitorLutPackImportTests." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let preferences = try #require(UserDefaults(suiteName: name))
        defer {
            preferences.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = CustomLUTStore(
            root: root.appendingPathComponent("luts"),
            preferences: LUTPreferences(storage: preferences, namespace: name))
        try body(try store.category(named: "vendor"), root)
    }

    private func entry(_ path: String, _ body: String) -> CustomLUTArchiveEntry {
        let bytes = body == "ok" ? valid : Data(body.utf8)
        return .init(path: path, uncompressedSize: UInt64(bytes.count)) { consume in
            try consume(bytes)
        }
    }

    /// A file whose first bytes are a local-file ZIP signature, as the download leaves it.
    private func zipFile(in root: URL, _ name: String = "pack.zip") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data([0x50, 0x4B, 0x03, 0x04, 0, 0]).write(to: url)
        return url
    }

    @Test func zipCubesImportAndRefusalsAreCounted() throws {
        try withStore { vendor, root in
            let pack = [
                entry("__MACOSX/._a.cube", "junk"), entry("Looks/A.cube", "ok"),
                entry("/B.cube", "ok"), entry("C.cube", "bad"),
            ]
            let result = vendor.importPack(file: try zipFile(in: root)) { accept in
                for member in pack { try accept(member) }
            }
            #expect(
                result
                    == MonitorLutPackImportResult(
                        importedCount: 2, foundCubeEntries: 3, rejectedCubeEntries: 1))
            #expect(vendor.list().map(\.fileName).sorted() == ["A.cube", "B.cube"])
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: vendor.root.path)
            #expect(leftovers.allSatisfy { !$0.hasPrefix(".lut-import-") }, "staging is cleaned")
        }
    }

    @Test func loneCubeAndNonArchivesAreReported() throws {
        try withStore { vendor, root in
            let cube = root.appendingPathComponent("Single.cube")
            try valid.write(to: cube)
            #expect(
                vendor.importPack(file: cube) { _ in Issue.record("a cube is not walked") }
                    == MonitorLutPackImportResult(
                        importedCount: 1, foundCubeEntries: 1, rejectedCubeEntries: 0))
            let page = root.appendingPathComponent("page.zip")
            try Data("<html>terms</html>".utf8).write(to: page)
            #expect(
                vendor.importPack(file: page) { _ in Issue.record("a page is not walked") }
                    == MonitorLutPackImportResult(importedCount: 0, notAnArchive: true))
            let empty = try zipFile(in: root, "empty.zip")
            #expect(
                vendor.importPack(file: empty) { accept in try accept(entry("readme.txt", "none")) }
                    == MonitorLutPackImportResult(importedCount: 0, foundCubeEntries: 0))
        }
    }

    @Test func cubeNamesAreSanitisedToSafeBasenames() {
        #expect(sanitizeLutCubeFileName("../dir/My LUT (1).cube") == "My_LUT__1_.cube")
        #expect(sanitizeLutCubeFileName("folder/") == "lut.cube")
    }

    /// An archive the adapter cannot walk keeps the reader's words for the host's copy, and a pack
    /// over the file limit stops as an archive error, as the Kotlin reader's limit does.
    @Test func unreadableArchivesAndLimitsAreArchiveErrors() throws {
        struct Unreadable: LocalizedError {
            var errorDescription: String? { "bad central directory" }
        }
        try withStore { vendor, root in
            let zip = try zipFile(in: root)
            let broken = vendor.importPack(file: zip) { _ in throw Unreadable() }
            #expect(
                broken
                    == MonitorLutPackImportResult(
                        importedCount: 0, foundCubeEntries: 0,
                        archiveError: "bad central directory"))
            let capped = vendor.importPack(
                file: zip, limits: CustomLUTArchiveLimits(maximumFiles: 1)
            ) { accept in
                try accept(entry("A.cube", "ok"))
                try accept(entry("B.cube", "ok"))
            }
            #expect(capped.importedCount == 1)
            #expect(capped.archiveError != nil)
        }
    }
}
