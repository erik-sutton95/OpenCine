import Foundation
import Testing

/// The package stays UI-free and app-free: sources import Foundation and OpenCine Core-area products
/// only (plan VENDOR-01 gate "no UI dependency").
@Suite struct ImportRuleTests {
    @Test func sourcesImportOnlyFoundationAndOpenCineCore() throws {
        let allowed: Set = [
            "Foundation", "OpenCineCore", "OpenCineMedia", "OpenCineMotion", "OpenCineCameraVocabulary",
        ]
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenCineDJI")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let words = line.split(separator: " ").map(String.init)
                guard let index = words.firstIndex(of: "import"), index + 1 < words.count,
                    words[..<index].allSatisfy({ $0.hasPrefix("@") })
                else { continue }
                #expect(allowed.contains(words[index + 1]), "\(file): \(line)")
            }
        }
    }
}
