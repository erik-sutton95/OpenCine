import Foundation
import Testing

/// GR-01 gate: the portable gyro engine imports Foundation only, holds no global mutable state,
/// names no app or manufacturer, and the minimum Core products never import it.
@Suite struct GyroSourceRulesTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func swiftFiles(_ directory: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root.appending(path: directory), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
    }

    @Test func gyroImportsOnlyFoundationAndNamesNoAppOrManufacturer() throws {
        let files = try Self.swiftFiles("Sources/OpenCineGyro")
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("import ") else { continue }
                #expect(line == "import Foundation", "\(file.lastPathComponent): \(line)")
            }
            #expect(
                !text.contains("static var"),
                "\(file.lastPathComponent) has mutable static state")
            #expect(!text.contains("nonisolated(unsafe)"), "\(file.lastPathComponent)")
            for appOwned in [
                "UserDefaults", "Bundle.main", "OpenZCine", "OpenPocketCine", "OpenInstaCine",
                "Nikon", "DJI", "Insta360",
            ] {
                #expect(
                    !text.contains(appOwned), "\(file.lastPathComponent) names \(appOwned)")
            }
        }
    }

    @Test func minimumCoreProductsNeverImportGyro() throws {
        for directory in ["Sources/OpenCineCore", "Sources/OpenCineMedia"] {
            for file in try Self.swiftFiles(directory) {
                let text = try String(contentsOf: file, encoding: .utf8)
                #expect(!text.contains("OpenCineGyro"), "\(file.lastPathComponent)")
            }
        }
    }
}
