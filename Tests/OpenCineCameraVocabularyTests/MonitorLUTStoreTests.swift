import Foundation
import OpenCineMedia
import Testing

@testable import OpenCineCameraVocabulary

@Suite struct MonitorLUTStoreTests {
    private static let cubeText =
        "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"

    private func defaults() -> UserDefaults {
        let name = "MonitorLUTStoreTests.\(UUID().uuidString)"
        let storage = UserDefaults(suiteName: name)!
        storage.removePersistentDomain(forName: name)
        return storage
    }

    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "MonitorLUTStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func source(_ fileName: String) throws -> URL {
        let dir = folder()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)
        try Self.cubeText.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The apps' saved LUT choices load from their own key names.
    @Test func preferencesKeepTheAppKeyNames() {
        let storage = defaults()
        let prefs = LUTPreferences(storage: storage, namespace: "App")
        prefs.lutSelection = .customFile
        prefs.lastLUT = "Mono"
        prefs.lastCustomFileName = "a.cube"
        prefs.lastLUTWasCustom = true
        prefs.setCustomFileName("r.cube", for: .rec709)
        prefs.setCustomFileName("d.cube", for: .dLog)
        prefs.setCustomFileName("d2.cube", for: .dLog2)
        prefs.selectedCustomFileName = "s.cube"
        prefs.lastMonitorColorMode = .dLog2

        #expect(storage.string(forKey: "App.LUTSelection") == "customFile")
        #expect(storage.string(forKey: "App.LastLUT") == "Mono")
        #expect(storage.string(forKey: "App.LastCustomLUT") == "a.cube")
        #expect(storage.bool(forKey: "App.LastLUTWasCustom"))
        #expect(storage.string(forKey: "App.CustomRec709File") == "r.cube")
        #expect(storage.string(forKey: "App.CustomDLogFile") == "d.cube")
        #expect(storage.string(forKey: "App.CustomDLog2File") == "d2.cube")
        #expect(storage.string(forKey: "App.SelectedCustomLUTFile") == "s.cube")
        #expect(storage.integer(forKey: "App.LastMonitorColorMode") == Int(ColorMode.dLog2.rawValue))

        prefs.lastMonitorColorMode = nil
        #expect(storage.object(forKey: "App.LastMonitorColorMode") == nil)
        #expect(prefs.lastLUT == CustomLUTIndex.displayName(fileName: "a.cube"))
    }

    @Test func freshPreferencesDefaultToOfficialAuto() {
        let prefs = LUTPreferences(storage: defaults(), namespace: "App")
        #expect(prefs.lutSelection == .officialAuto)
        #expect(prefs.lastBuiltInLUT == LUTSelection.auto.title)
        #expect(prefs.lastMonitorColorMode == nil)
        #expect(prefs.selectedCustomFileName == nil)
    }

    @Test func unsafeSelectedFileNamesDoNotLoad() {
        let storage = defaults()
        storage.set("../escape.cube", forKey: "App.SelectedCustomLUTFile")
        #expect(LUTPreferences(storage: storage, namespace: "App").selectedCustomFileName == nil)
    }

    /// Old Built-in looks become Auto; a stored custom file becomes Custom D-Log while LUT is on.
    @Test func legacySelectionMigratesOnce() {
        let storage = defaults()
        let prefs = LUTPreferences(storage: storage, namespace: "App")
        prefs.lastLUTWasCustom = true
        prefs.lastCustomFileName = "old.cube"
        prefs.migrateLegacySelectionIfNeeded(lutEnabled: true)
        #expect(prefs.lutSelection == .customDLog)
        #expect(prefs.customFileName(for: .dLog) == "old.cube")

        prefs.lutSelection = .creativeWarm
        prefs.migrateLegacySelectionIfNeeded(lutEnabled: true)
        #expect(prefs.lutSelection == .creativeWarm)

        let off = LUTPreferences(storage: defaults(), namespace: "App")
        off.lastLUTWasCustom = true
        off.lastCustomFileName = "old.cube"
        off.migrateLegacySelectionIfNeeded(lutEnabled: false)
        #expect(off.lutSelection == .officialAuto)
        #expect(off.customFileName(for: .dLog) == "old.cube")
    }

    /// A slot's previous file goes when replaced or cleared, unless another slot still uses it.
    @Test func customSlotsReplaceAndShareFiles() throws {
        let prefs = LUTPreferences(storage: defaults(), namespace: "App")
        let store = CustomLUTStore(root: folder(), preferences: prefs)
        defer { try? FileManager.default.removeItem(at: store.root) }

        try store.importFile(from: source("a.cube"), into: .dLog)
        try store.importFile(from: source("a.cube"), into: .dLog2)
        #expect(store.hasCube(.dLog) && store.hasCube(.dLog2))
        #expect(store.cube(.dLog)?.size == 2)
        #expect(store.displayName(for: .dLog) == CustomLUTIndex.displayName(fileName: "a.cube"))

        try store.importFile(from: source("b.cube"), into: .dLog)
        #expect(store.fileName(for: .dLog) == "b.cube")
        #expect(store.list().map(\.fileName).sorted() == ["a.cube", "b.cube"])

        try store.clear(.dLog2)
        #expect(!store.hasCube(.dLog2))
        #expect(store.list().map(\.fileName) == ["b.cube"])
        #expect(store.cube(fileName: "a.cube") == nil)
        #expect(throws: CustomLUTStoreError.self) {
            try store.importFile(from: folder().appendingPathComponent("missing.cube"))
        }
    }

    /// A1-57: a named library (Z's RED download beside its imports) is a kept store in its own
    /// folder; only a single safe folder name opens one.
    @Test func namedLibrariesAreKeptStoresInTheirOwnFolders() throws {
        let store = CustomLUTStore(root: folder(), preferences: LUTPreferences(storage: defaults(), namespace: "App"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let red = try #require(store.library("red"))
        #expect(red.root == store.root.appendingPathComponent("red", isDirectory: true))
        #expect(store.library("red") === red)
        #expect(store.library("..") == nil && store.library("a/b") == nil && store.library("") == nil)

        try red.importFile(from: source("Look.cube"))
        #expect(red.list().map(\.fileName) == ["Look.cube"])
        #expect(store.list().isEmpty)
    }

    /// A1-57: the bounded archive import flattens folders, skips other entries and unsafe names,
    /// replaces a same-named cube and stops at each limit.
    @Test func archiveImportFlattensSkipsAndStopsAtTheLimits() throws {
        let store = CustomLUTStore(root: folder(), preferences: LUTPreferences(storage: defaults(), namespace: "App"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.importFile(from: source("B.cube"))
        #expect(store.cube(fileName: "B.cube")?.size == 2)
        let entries: [(path: String, bytes: UInt64)] = [
            ("Pack/Rec709/A.cube", 40), ("Pack/readme.txt", 10), ("Pack/Bad:Name.cube", 10),
            ("Pack/..", 10), ("Pack/Huge.cube", 101), ("Pack/B.cube", 40), ("Pack/C.cube", 40),
            ("Pack/D.cube", 40), ("Pack/E.cube", 40),
        ]
        var extracted: [String] = []
        let stored = try store.importArchive(
            entries, path: { $0.path }, size: { $0.bytes },
            limits: CustomLUTArchiveLimits(maxEntryBytes: 100, maxTotalBytes: 130, maxFiles: 4)
        ) { entry, destination in
            extracted.append(entry.path)
            #expect(destination.deletingLastPathComponent().standardizedFileURL == store.root.standardizedFileURL)
            try "replaced".write(to: destination, atomically: true, encoding: .utf8)
        }
        // A, B and C take 120 of the 130 bytes; D and E would pass the total.
        #expect(extracted == ["Pack/Rec709/A.cube", "Pack/B.cube", "Pack/C.cube"])
        #expect(stored.map(\.fileName) == ["A.cube", "B.cube", "C.cube"])
        // The replaced cube is not served from the old parse.
        #expect(store.cube(fileName: "B.cube") == nil)

        let few = try store.importArchive(
            ["X.cube", "Y.cube"], path: { $0 }, size: { _ in 1 },
            limits: CustomLUTArchiveLimits(maxFiles: 1)
        ) { _, destination in try Self.cubeText.write(to: destination, atomically: true, encoding: .utf8) }
        #expect(few.map(\.fileName).contains("X.cube") && !few.map(\.fileName).contains("Y.cube"))
    }

    @Test func archiveImportChecksActualBytesAndPreservesTheExistingCube() throws {
        let store = CustomLUTStore(root: folder(), preferences: LUTPreferences(storage: defaults(), namespace: "App"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.importFile(from: source("Existing.cube"))
        let original = try Data(contentsOf: store.root.appendingPathComponent("Existing.cube"))
        #expect(throws: CustomLUTStoreError.self) {
            try store.importArchive(["Existing.cube"], path: { $0 }, size: { _ in 1 },
                limits: .init(maxEntryBytes: 4, maxTotalBytes: 4)) { _, destination in
                    try Data(repeating: 1, count: 8).write(to: destination)
                }
        }
        #expect(try Data(contentsOf: store.root.appendingPathComponent("Existing.cube")) == original)
        #expect(store.cube(fileName: "Existing.cube")?.size == 2)
        #expect(store.list().map(\.fileName) == ["Existing.cube"])
    }

    @Test func aFailedArchiveReplacementPreservesTheExistingCube() throws {
        let store = CustomLUTStore(root: folder(), preferences: LUTPreferences(storage: defaults(), namespace: "App"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.importFile(from: source("Existing.cube"))
        let original = try Data(contentsOf: store.root.appendingPathComponent("Existing.cube"))
        #expect(throws: CocoaError.self) {
            try store.importArchive(["Existing.cube"], path: { $0 }, size: { _ in 1 }) { _, destination in
                try Data([1]).write(to: destination)
                throw CocoaError(.fileWriteUnknown)
            }
        }
        #expect(try Data(contentsOf: store.root.appendingPathComponent("Existing.cube")) == original)
        #expect(store.cube(fileName: "Existing.cube")?.size == 2)
    }

    @Test func streamedArchiveRefusesExcessActualBytesBeforeWritingThem() throws {
        let store = CustomLUTStore(root: folder(), preferences: LUTPreferences(storage: defaults(), namespace: "App"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.importFile(from: source("Existing.cube"))
        let original = try Data(contentsOf: store.root.appendingPathComponent("Existing.cube"))
        var chunks = 0
        #expect(throws: CustomLUTStoreError.self) {
            try store.importArchive(["Existing.cube"], path: { $0 }, size: { _ in 1 },
                limits: .init(maxEntryBytes: 4, maxTotalBytes: 4), read: { _, consume in
                    for _ in 0..<3 {
                        chunks += 1
                        try consume(Data(repeating: 1, count: 3))
                    }
                })
        }
        #expect(chunks == 2)
        #expect(try Data(contentsOf: store.root.appendingPathComponent("Existing.cube")) == original)
        #expect(store.list().map(\.fileName) == ["Existing.cube"])
    }

    /// A1-57: `.` and `..` name the library and its parent, so removal refuses them.
    @Test func removingDotNamesLeavesTheLibraryAndItsParent() throws {
        let parent = folder()
        let store = CustomLUTStore(
            root: parent.appendingPathComponent("library", isDirectory: true),
            preferences: LUTPreferences(storage: defaults(), namespace: "App"))
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let keep = parent.appendingPathComponent("keep.cube")
        try Self.cubeText.write(to: keep, atomically: true, encoding: .utf8)

        for name in [".", ".."] {
            #expect(throws: CustomLUTStoreError.self) { try store.remove(StoredCustomLUT(fileName: name)) }
        }
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(FileManager.default.fileExists(atPath: store.root.path))
    }

    /// A1-57: parsed cubes stay bounded while an operator auditions a large library.
    @Test func parsedCubesStayBounded() throws {
        let store = CustomLUTStore(root: folder(), preferences: LUTPreferences(storage: defaults(), namespace: "App"))
        defer { try? FileManager.default.removeItem(at: store.root) }
        for index in 0..<(CustomLUTStore.cachedCubeLimit + 4) {
            try store.importFile(from: source("Look \(index).cube"))
        }
        #expect(store.cachedCubeCount == CustomLUTStore.cachedCubeLimit)
        #expect(store.cube(fileName: "Look 0.cube")?.size == 2)
    }

    /// Live Photo is Rec.709: technical log conversions resolve to Off, creative looks stay.
    @Test func livePhotoSuppressesTechnicalLogConversions() {
        let photo = { (selection: LUTSelection) in
            LiveLUTResolver.resolve(
                selection: selection, colorMode: .dLog2, hasCustomDLog: true,
                hasCustomDLog2: true, isPhoto: true)
        }
        #expect(photo(.officialAuto) == .off)
        #expect(photo(.iLogRec709) == .off)
        #expect(photo(.customDLog2) == .off)
        #expect(photo(.creativeMono) == .creative(.mono))
        #expect(LiveMonitorColorScience.colorMode(isPhoto: true, colorMode: .dLog2) == .normal)
        #expect(LiveMonitorColorScience.colorMode(isPhoto: false, colorMode: .dLog2) == .dLog2)
    }
}
