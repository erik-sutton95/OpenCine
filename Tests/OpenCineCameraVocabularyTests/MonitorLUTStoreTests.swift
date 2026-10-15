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
