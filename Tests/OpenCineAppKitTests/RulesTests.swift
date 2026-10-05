import Foundation
import Testing

/// The app shell builds on Core, Multicam and the shared UI only: never an integration or an app
/// (AGENTS.md boundaries). Brand names and mutable globals are checked with the shared UI rules
/// (`SharedUIRulesTests`). Kotlin mirror: `AppKitRulesTest`.
struct AppKitRules {
    @Test func appKitImportsNoIntegrationOrApp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appending(path: "Sources/OpenCineAppKit")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        let allowed: Set<String> = [
            "Foundation", "Observation", "SwiftUI", "UIKit", "OpenCineCore", "OpenCineMulticam",
            "MonitorPresentation", "MonitorUI", "OpenCineMedia",
            // The reliability network policy reads a gzip envelope header (system zlib).
            "zlib",
            // Reporting watches for a usable internet path (system Network); the problem report
            // normalizes attached images (system ImageIO, UniformTypeIdentifiers, CoreTransferable).
            "Network", "ImageIO", "UniformTypeIdentifiers", "CoreTransferable",
            // The diagnostic journal writes the unified log (system os).
            "os",
        ]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            where line.hasPrefix("import ") {
                #expect(allowed.contains(String(line.dropFirst("import ".count))), "\(file.lastPathComponent): \(line)")
            }
        }
        let manifest = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        let target = try #require(manifest.firstMatch(of: #/\.target\(\s*name: "OpenCineAppKit",\s*dependencies: \[([^\]]*)\]/#))
        let dependencies = target.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: ["\""]) }
        #expect(!dependencies.isEmpty && Set(dependencies).isSubset(of: allowed))
    }
}
