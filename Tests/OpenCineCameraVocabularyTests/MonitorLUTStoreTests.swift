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
        #expect(
            storage.integer(forKey: "App.LastMonitorColorMode") == Int(ColorMode.dLog2.rawValue))

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

    @Test func importingStoredFileOntoItselfPreservesValidCube() throws {
        let prefs = LUTPreferences(storage: defaults(), namespace: "App")
        let store = CustomLUTStore(root: folder(), preferences: prefs)
        defer { try? FileManager.default.removeItem(at: store.root) }
        let imported = try store.importFile(from: source("same.cube"))
        let destination = store.root.appendingPathComponent(imported.fileName)
        let before = try Data(contentsOf: destination)
        try store.importFile(from: destination)
        #expect(try Data(contentsOf: destination) == before)
        #expect(store.cube(imported)?.size == 2)
    }

    @Test func independentCategoryStoreReadsAtomicReplacementWithSameSizeAndDate() throws {
        let prefs = LUTPreferences(storage: defaults(), namespace: "App")
        let root = folder()
        let model = try CustomLUTStore(root: root, preferences: prefs).category(named: "custom")
        let watch = try CustomLUTStore(root: root, preferences: prefs).category(named: "custom")
        let file = try source("same.cube")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        let stored = try model.importFile(from: file)
        let destination = model.root.appendingPathComponent(stored.fileName)
        // Whole-second metadata avoids rounding when FileManager restores an APFS timestamp.
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: destination.path)
        #expect(Array(try #require(watch.cube(stored)).rgb.prefix(3)) == [0, 0, 0])
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect(attributes[.modificationDate] as? Date == date)
        let replacement = Self.cubeText.replacingOccurrences(of: "0 0 0\n", with: "1 1 1\n")
        #expect(replacement.utf8.count == Self.cubeText.utf8.count)
        try Data(replacement.utf8).write(to: file)
        try model.importFile(from: file)
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: destination.path)
        let replacedAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect(replacedAttributes[.modificationDate] as? Date == date)
        #expect(replacedAttributes[.size] as? NSNumber == attributes[.size] as? NSNumber)
        #expect(Array(try #require(watch.cube(stored)).rgb.prefix(3)) == [1, 1, 1])
    }

    @Test func independentCategoryStoreDoesNotReturnDeletedCube() throws {
        let prefs = LUTPreferences(storage: defaults(), namespace: "App")
        let root = folder()
        let model = try CustomLUTStore(root: root, preferences: prefs).category(named: "custom")
        let watch = try CustomLUTStore(root: root, preferences: prefs).category(named: "custom")
        let file = try source("delete.cube")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        let stored = try model.importFile(from: file)
        #expect(watch.cube(stored) != nil)
        try model.remove(stored)
        #expect(watch.cube(stored) == nil)
    }

    @Test func storedSymlinkCannotReadAnOutsideCube() throws {
        let prefs = LUTPreferences(storage: defaults(), namespace: "App")
        let store = CustomLUTStore(root: folder(), preferences: prefs)
        let outside = try source("outside.cube")
        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: outside.deletingLastPathComponent())
        }
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: store.root.appendingPathComponent("link.cube"),
            withDestinationURL: outside)
        #expect(store.cube(fileName: "link.cube") == nil)
    }

    @Test func directImportKeepsOperatorNameAndValidatedCubeSamples() throws {
        let prefs = LUTPreferences(storage: defaults(), namespace: "App")
        let store = CustomLUTStore(root: folder(), preferences: prefs)
        let file = try source("Clean Whites.cube")
        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        let text =
            "TITLE \"Generated by Resolve\"\n"
            + Self.cubeText.replacingOccurrences(
                of: "0 0 0\n", with: "0.03 0.04 0.05\n")
        try Data(text.utf8).write(to: file)
        let stored = try store.importFile(from: file)
        let cube = try #require(store.cube(stored))
        #expect(stored.fileName == "Clean Whites.cube")
        #expect(cube.size == 2)
        #expect(Array(cube.rgb.prefix(3)) == [0.03, 0.04, 0.05])
    }

    @Test func malformedReplacementNeverOverwritesUsableCube() throws {
        let prefs = LUTPreferences(storage: defaults(), namespace: "App")
        let store = CustomLUTStore(root: folder(), preferences: prefs)
        let file = try source("valid.cube")
        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        try store.importFile(from: file)
        let destination = store.root.appendingPathComponent(file.lastPathComponent)
        let original = try Data(contentsOf: destination)
        try Data("LUT_3D_SIZE 66\n0 0 0\n".utf8).write(to: file)
        #expect(throws: (any Error).self) { try store.importFile(from: file) }
        #expect(try Data(contentsOf: destination) == original)
        #expect(store.cube(fileName: file.lastPathComponent)?.size == 2)
    }

    @Test func deletionRemovesOnlySafeStoredFilesAndPreservesOutsideFile() throws {
        let prefs = LUTPreferences(storage: defaults(), namespace: "App")
        let store = CustomLUTStore(root: folder(), preferences: prefs)
        let file = try source("delete.cube")
        defer {
            try? FileManager.default.removeItem(at: store.root)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
        }
        let stored = try store.importFile(from: file)
        try store.remove(stored)
        #expect(store.list().isEmpty)
        #expect(store.cube(stored) == nil)
        let child = try store.category(named: "custom")
        #expect(throws: CustomLUTStoreError.self) {
            try child.remove(StoredCustomLUT(fileName: "../outside.cube"))
        }
        #expect(try Data(contentsOf: file) == Data(Self.cubeText.utf8))
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
