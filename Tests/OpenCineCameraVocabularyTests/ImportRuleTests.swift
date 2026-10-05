import Foundation
import Testing

/// The camera vocabulary builds on Core, Media and Motion only: no UI, integration, app or wire code
/// (AGENTS.md boundaries). Kotlin mirror: module `camera-vocabulary`.
@Suite struct ImportRuleTests {
    @Test func vocabularyImportsOnlyCoreMediaAndMotion() throws {
        let allowed: Set = ["Foundation", "OpenCineCore", "OpenCineMedia", "OpenCineMotion"]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appending(path: "Sources/OpenCineCameraVocabulary")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let words = line.split(separator: " ").map(String.init)
                guard let index = words.firstIndex(of: "import"), index + 1 < words.count,
                    words[..<index].allSatisfy({ $0.hasPrefix("@") })
                else { continue }
                #expect(allowed.contains(words[index + 1]), "\(file.lastPathComponent): \(line)")
            }
        }
        let manifest = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        let target = try #require(
            manifest.firstMatch(of: #/\.target\(\s*name: "OpenCineCameraVocabulary",\s*dependencies: \[([^\]]*)\]/#))
        let dependencies = target.1.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: ["\""]) }
        #expect(!dependencies.isEmpty && Set(dependencies).isSubset(of: allowed))
    }
}
