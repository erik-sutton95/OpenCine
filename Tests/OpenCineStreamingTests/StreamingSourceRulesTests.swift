import Foundation
import Testing

/// The portable streaming engine imports Foundation and Core only, holds no global mutable state,
/// opens no socket and names no app or manufacturer. Service names appear only as preset content.
@Suite struct StreamingSourceRulesTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func swiftFiles(_ directory: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root.appending(path: directory), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
    }

    @Test func streamingImportsOnlyFoundationAndCoreAndNamesNoAppOrManufacturer() throws {
        let files = try Self.swiftFiles("Sources/OpenCineStreaming")
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("import ") else { continue }
                #expect(
                    line == "import Foundation" || line == "import OpenCineCore",
                    "\(file.lastPathComponent): \(line)")
            }
            #expect(!text.contains("static var"), "\(file.lastPathComponent) has mutable static state")
            #expect(!text.contains("nonisolated(unsafe)"), "\(file.lastPathComponent)")
            for appOwned in [
                "UserDefaults", "Bundle.main", "OpenZCine", "OpenPocketCine", "OpenInstaCine",
                "Nikon", "DJI", "Insta360", "Luna",
            ] {
                #expect(!text.contains(appOwned), "\(file.lastPathComponent) names \(appOwned)")
            }
        }
    }

    @Test func minimumCoreProductsNeverImportStreaming() throws {
        for directory in ["Sources/OpenCineCore", "Sources/OpenCineMedia"] {
            for file in try Self.swiftFiles(directory) {
                let text = try String(contentsOf: file, encoding: .utf8)
                #expect(!text.contains("OpenCineStreaming"), "\(file.lastPathComponent)")
            }
        }
    }
}
