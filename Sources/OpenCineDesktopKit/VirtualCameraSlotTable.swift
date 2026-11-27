import Foundation

/// Which module owns which driver slot. A slot is given once and kept, so a saved scene in a
/// receiving app keeps finding the same camera.
public struct VirtualCameraSlotTable: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct Assignment: Codable, Equatable, Sendable {
        public let slot: Int
        public let moduleID: String
        public var displayName: String

        public init(slot: Int, moduleID: String, displayName: String) {
            self.slot = slot
            self.moduleID = moduleID
            self.displayName = displayName
        }
    }

    public var version: Int
    public private(set) var assignments: [Assignment]

    public init() {
        version = Self.currentVersion
        assignments = []
    }

    /// The module's slot, assigning the next free one the first time. `nil` when every slot is taken.
    @discardableResult
    public mutating func assign(moduleID: String, displayName: String) -> VirtualCameraSlot? {
        if let index = assignments.firstIndex(where: { $0.moduleID == moduleID }) {
            assignments[index].displayName = displayName
            return VirtualCameraSlot(number: assignments[index].slot)
        }
        let taken = Set(assignments.map(\.slot))
        guard let free = VirtualCameraSlot.all.first(where: { !taken.contains($0.number) }) else {
            return nil
        }
        assignments.append(
            Assignment(slot: free.number, moduleID: moduleID, displayName: displayName))
        return free
    }

    public func slot(forModule moduleID: String) -> VirtualCameraSlot? {
        assignments.first { $0.moduleID == moduleID }.flatMap { VirtualCameraSlot(number: $0.slot) }
    }
}

public enum VirtualCameraSlotTableError: Error, Equatable, Sendable {
    case corrupt
    case unsupportedVersion(Int)
}

/// The table's file. It is never overwritten with something that could reassign a slot.
public enum VirtualCameraSlotTableFile {
    /// A missing file is an empty table. Undecodable content moves to `<name>.corrupt` once, so it
    /// can be recovered, and throws. A newer version throws and leaves the file alone.
    public static func load(from url: URL) throws -> VirtualCameraSlotTable {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return VirtualCameraSlotTable()
        }
        let table: VirtualCameraSlotTable
        do {
            table = try JSONDecoder().decode(VirtualCameraSlotTable.self, from: data)
        } catch {
            let aside = url.appendingPathExtension("corrupt")
            if !FileManager.default.fileExists(atPath: aside.path) {
                try? FileManager.default.moveItem(at: url, to: aside)
            }
            throw VirtualCameraSlotTableError.corrupt
        }
        guard table.version == VirtualCameraSlotTable.currentVersion else {
            throw VirtualCameraSlotTableError.unsupportedVersion(table.version)
        }
        return table
    }

    public static func save(_ table: VirtualCameraSlotTable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(table).write(to: url, options: .atomic)
    }
}

/// How the dock hands the table to the driver: a custom Core Media IO property on the first input.
/// The driver's sandbox cannot read a file the dock writes. Its temporary file exception makes the
/// macOS profile fail to compile (`cmioextension.sb`, `(allow filter)` with no operation), and the
/// driver runs as another user, so an app group container is not shared either.
public enum VirtualCameraSlotTableWire {
    /// The property's Core Media IO selector, and its name on the driver's side.
    public static let selector = "ocst"
    public static let propertyName = "4cc_ocst_glob_0000"
    public static let maximumBytes = 4_096
    public static let maximumNameLength = 64

    /// Stable for equal tables, so the dock can compare the driver's read-back.
    public static func encode(_ table: VirtualCameraSlotTable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(table), as: UTF8.self)
    }

    /// Any local process can write this property, so the driver takes only a table it can publish
    /// safely. `nil` for anything else, which leaves the published inputs as they are.
    public static func decode(_ text: String) -> VirtualCameraSlotTable? {
        guard text.utf8.count <= maximumBytes,
            let table = try? JSONDecoder().decode(
                VirtualCameraSlotTable.self, from: Data(text.utf8)),
            table.version == VirtualCameraSlotTable.currentVersion
        else { return nil }
        let assignments = table.assignments
        guard Set(assignments.map(\.slot)).count == assignments.count,
            Set(assignments.map(\.moduleID)).count == assignments.count
        else { return nil }
        for assignment in assignments {
            let name = assignment.displayName
            guard VirtualCameraSlot(number: assignment.slot) != nil, !name.isEmpty,
                name.count <= maximumNameLength,
                !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
        }
        return table
    }
}
