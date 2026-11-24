import Foundation
import Testing

@testable import OpenCineDesktopKit

@Suite struct VirtualCameraSlotTests {
    @Test func slotIdentifiersAreFixedForever() {
        let s = VirtualCameraSlot.all[0]
        #expect(VirtualCameraSlot.all.count == 8)
        #expect(s.legacyDeviceID == "OpenCine.Camera.1")
        #expect(s.deviceUUID.uuidString == "6F70656E-6369-4E65-8000-000000000010")
        #expect(s.sourceStreamUUID.uuidString == "6F70656E-6369-4E65-8000-000000000011")
        #expect(s.sinkStreamUUID.uuidString == "6F70656E-6369-4E65-8000-000000000012")
        #expect(s.sinkStreamName == "OpenCine.Camera.1.sink")
        #expect(VirtualCameraSlot.all[7].sinkStreamUUID.uuidString == "6F70656E-6369-4E65-8000-000000000082")
    }

    @Test func slotNumbersOutsideThePoolDoNotExist() {
        #expect(VirtualCameraSlot(number: 0) == nil)
        #expect(VirtualCameraSlot(number: 9) == nil)
    }
}

@Suite struct VirtualCameraSlotTableTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    }

    @Test func assigningTwiceKeepsTheSlot() {
        var t = VirtualCameraSlotTable()
        #expect(t.assign(moduleID: "a", displayName: "A")?.number == 1)
        #expect(t.assign(moduleID: "b", displayName: "B")?.number == 2)
        #expect(t.assign(moduleID: "a", displayName: "A renamed")?.number == 1)
        #expect(t.assignments.first?.displayName == "A renamed")
        #expect(t.slot(forModule: "b")?.number == 2)
        #expect(t.slot(forModule: "c") == nil)
    }

    @Test func aNinthModuleGetsNoSlot() {
        var t = VirtualCameraSlotTable()
        for i in 1...8 { #expect(t.assign(moduleID: "m\(i)", displayName: "M")?.number == i) }
        #expect(t.assign(moduleID: "m9", displayName: "M") == nil)
    }

    @Test func tableSurvivesSaveAndLoad() throws {
        let url = temporaryFile()
        var t = VirtualCameraSlotTable()
        t.assign(moduleID: "a", displayName: "A")
        try VirtualCameraSlotTableFile.save(t, to: url)
        #expect(try VirtualCameraSlotTableFile.load(from: url) == t)
    }

    @Test func missingTableLoadsEmpty() throws {
        let t = try VirtualCameraSlotTableFile.load(from: temporaryFile())
        #expect(t.assignments.isEmpty)
        #expect(t.version == 1)
    }

    @Test func corruptTableIsPreservedNotOverwritten() throws {
        let url = temporaryFile()
        try Data("{oops".utf8).write(to: url)
        #expect(throws: VirtualCameraSlotTableError.corrupt) {
            try VirtualCameraSlotTableFile.load(from: url)
        }
        let aside = url.appendingPathExtension("corrupt")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{oops")
    }

    @Test func futureVersionIsRefusedAndUntouched() throws {
        let url = temporaryFile()
        let future = Data(#"{"version":2,"assignments":[]}"#.utf8)
        try future.write(to: url)
        #expect(throws: VirtualCameraSlotTableError.unsupportedVersion(2)) {
            try VirtualCameraSlotTableFile.load(from: url)
        }
        #expect(try Data(contentsOf: url) == future)
    }
}

@Suite struct ModuleManifestTests {
    private func manifest(minimum: String) -> ModuleManifest {
        ModuleManifest(
            id: "x", displayName: "X", inputName: "OpenCine X", version: "1.0.0",
            minimumDockVersion: minimum, bundleName: "X.app")
    }

    @Test func comparesVersionsNumerically() {
        #expect(manifest(minimum: "1.2.0").isCompatible(withDock: "1.10.0"))
        #expect(manifest(minimum: "1.2.0").isCompatible(withDock: "1.2.0"))
        #expect(!manifest(minimum: "1.2.0").isCompatible(withDock: "1.1.9"))
    }
}

@Suite struct DockMessageTests {
    @Test func messagesRoundTripAcrossEveryFragment() throws {
        let messages: [DockMessage] = [
            .show(frame: WindowFrame(x: 1, y: 2, width: 3, height: 4)), .hide, .quit,
        ]
        let wire = try messages.reduce(Data()) { $0 + (try LengthPrefixedJSON.encode($1)) }
        for split in 0...wire.count {
            var buffer = Data(wire.prefix(split))
            var received: [DockMessage] = try LengthPrefixedJSON.decodeAll(&buffer)
            buffer.append(wire.dropFirst(split))
            received += try LengthPrefixedJSON.decodeAll(&buffer)
            #expect(received == messages)
            #expect(buffer.isEmpty)
        }
    }

    @Test func tabAndWindowMessagesRoundTrip() throws {
        let frame = WindowFrame(x: 10, y: 20, width: 1280, height: 800)
        let dock: [DockMessage] = [
            .tabs(
                [
                    DockTab(id: "a", displayName: "A", state: .live),
                    DockTab(id: "b", displayName: "B", state: .stopped),
                ], selectedID: "a",
                notice: DockNotice(text: "Turn on camera driver", opensDriverSettings: true)),
            .tabs([], selectedID: nil, notice: nil),
            .place(frame: frame),
        ]
        let module: [ModuleMessage] = [
            .selectTab(id: "b"), .windowFrame(frame, final: true), .windowFrame(frame, final: false),
            .shown, .closeRequested,
        ]
        var dockWire = try dock.reduce(Data()) { $0 + (try LengthPrefixedJSON.encode($1)) }
        var moduleWire = try module.reduce(Data()) { $0 + (try LengthPrefixedJSON.encode($1)) }
        let dockReceived: [DockMessage] = try LengthPrefixedJSON.decodeAll(&dockWire)
        let moduleReceived: [ModuleMessage] = try LengthPrefixedJSON.decodeAll(&moduleWire)
        #expect(dockReceived == dock)
        #expect(moduleReceived == module)
    }

    @Test func oversizedMessageThrows() {
        var buffer = Data([0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        #expect(throws: LengthPrefixedJSONError.messageTooLarge) {
            let _: [DockMessage] = try LengthPrefixedJSON.decodeAll(&buffer, maxMessageBytes: 1024)
        }
    }
}

@Suite struct ModuleRegistryTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func install(_ id: String, minimum: String = "1.0.0", in root: URL) throws {
        let folder = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("\(id).app"), withIntermediateDirectories: true)
        let manifest = ModuleManifest(
            id: id, displayName: id, inputName: "OpenCine \(id)", version: "1.0.0",
            minimumDockVersion: minimum, bundleName: "\(id).app")
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("module.json"))
    }

    @Test func listsModulesWithManifests() throws {
        let root = try directory()
        try install("b", in: root)
        try install("a", in: root)
        let found = ModuleRegistry(modulesDirectory: root, dockVersion: "1.0.0").installed()
        #expect(found.map(\.manifest.id) == ["a", "b"])
        #expect(found[0].compatible)
    }

    @Test func skipsFolderWithoutManifest() throws {
        let root = try directory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        #expect(ModuleRegistry(modulesDirectory: root, dockVersion: "1.0.0").installed().isEmpty)
    }

    @Test func flagsIncompatibleModule() throws {
        let root = try directory()
        try install("a", minimum: "2.0.0", in: root)
        let found = ModuleRegistry(modulesDirectory: root, dockVersion: "1.0.0").installed()
        #expect(found.first?.compatible == false)
    }

    @Test func badManifestDoesNotHideOthers() throws {
        let root = try directory()
        try install("good", in: root)
        let bad = root.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{oops".utf8).write(to: bad.appendingPathComponent("module.json"))
        let found = ModuleRegistry(modulesDirectory: root, dockVersion: "1.0.0").installed()
        #expect(found.map(\.manifest.id) == ["good"])
    }

    @Test func missingModulesFolderIsEmpty() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(ModuleRegistry(modulesDirectory: missing, dockVersion: "1.0.0").installed().isEmpty)
    }
}

@Suite struct DesktopKitSourceRulesTests {
    @Test func importsOnlyFoundationAndNamesNoManufacturerOrApp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(
            at: root.appending(path: "Sources/OpenCineDesktopKit"), includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where line.hasPrefix("import ") {
                #expect(line == "import Foundation", "\(file.lastPathComponent): \(line)")
            }
            #expect(!text.contains("static var"), "\(file.lastPathComponent)")
            #expect(!text.contains("nonisolated(unsafe)"), "\(file.lastPathComponent)")
            for name in ["Nikon", "DJI", "Insta360", "Luna", "OpenZCine", "OpenPocketCine", "OpenInstaCine"] {
                #expect(!text.contains(name), "\(file.lastPathComponent) names \(name)")
            }
        }
    }
}

@Suite("Slot table handed to the driver")
struct SlotTableWireTests {
    private func table() -> VirtualCameraSlotTable {
        var table = VirtualCameraSlotTable()
        table.assign(moduleID: "camera-a", displayName: "OpenCine Camera A")
        table.assign(moduleID: "camera-b", displayName: "OpenCine Camera B")
        return table
    }

    @Test func aTableSurvivesTheTrip() throws {
        let text = try VirtualCameraSlotTableWire.encode(table())
        #expect(VirtualCameraSlotTableWire.decode(text) == table())
    }

    @Test func encodingIsStableSoTheDockCanCompareTheReadBack() throws {
        #expect(
            try VirtualCameraSlotTableWire.encode(table())
                == VirtualCameraSlotTableWire.encode(table()))
    }

    private func payload(_ assignments: String, version: Int = 1) -> String {
        "{\"version\":\(version),\"assignments\":[\(assignments)]}"
    }

    private func entry(slot: Int, id: String = "a", name: String = "OpenCine A") -> String {
        "{\"slot\":\(slot),\"moduleID\":\"\(id)\",\"displayName\":\"\(name)\"}"
    }

    @Test func theDriverRefusesAnythingItCouldNotPublishSafely() {
        let refused = [
            "not json",
            payload(entry(slot: 0)),
            payload(entry(slot: 9)),
            payload(entry(slot: 1, name: "")),
            payload(entry(slot: 1, name: String(repeating: "x", count: 65))),
            payload(entry(slot: 1, name: "line\\nbreak")),
            payload(entry(slot: 1, id: "a") + "," + entry(slot: 1, id: "b")),
            payload(entry(slot: 1, id: "a") + "," + entry(slot: 2, id: "a")),
            payload(entry(slot: 1), version: 2),
            String(repeating: " ", count: VirtualCameraSlotTableWire.maximumBytes + 1),
        ]
        for text in refused {
            #expect(VirtualCameraSlotTableWire.decode(text) == nil, "\(text.prefix(80))")
        }
        #expect(VirtualCameraSlotTableWire.decode(payload(entry(slot: 8))) != nil)
    }
}
