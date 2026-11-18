import Foundation
import Testing

/// Streaming's Apple shell imports Foundation, Core, the portable engine and Apple system
/// frameworks only, holds no global mutable state and names no app or manufacturer.
@Suite struct StreamingAppleSourceRulesTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let allowedImports: Set<String> = [
        "Foundation", "OpenCineCore", "OpenCineStreaming", "AVFoundation", "AudioToolbox", "CoreMedia",
        "CoreVideo", "CoreImage", "Accelerate", "Network", "Security", "VideoToolbox", "UIKit",
    ]

    @Test func appleShellImportsOnlyItsLayersAndNamesNoAppOrManufacturer() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: Self.root.appending(path: "Sources/OpenCineStreamingApple"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("import ") else { continue }
                let module = line.dropFirst("import ".count).split(separator: " ").last.map(String.init) ?? ""
                #expect(Self.allowedImports.contains(module), "\(file.lastPathComponent): \(line)")
            }
            #expect(!text.contains("static var"), "\(file.lastPathComponent) has mutable static state")
            #expect(!text.contains("nonisolated(unsafe)"), "\(file.lastPathComponent)")
            for name in ["OpenZCine", "OpenPocketCine", "OpenInstaCine", "Nikon", "DJI", "Insta360", "Luna", "MonitorUI"] {
                #expect(!text.contains(name), "\(file.lastPathComponent) names \(name)")
            }
        }
    }
}
