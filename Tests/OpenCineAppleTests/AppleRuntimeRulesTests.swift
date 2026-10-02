import Foundation
import Testing

/// OpenCineApple contains the OS media frameworks: lower products never import it, every file is
/// compiled only where its frameworks exist (the package still builds off Apple platforms), and it
/// names no manufacturer. Integration hooks arrive as parameters.
@Suite struct AppleRuntimeRulesTests {
    @Test func importRules() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let brands = try Regex(
            #"\b(dji|osmo|nikon|zcine|insta360|insta|luna|pocket|sony|canon|blackmagic|gopro)\b"#
        ).ignoresCase()
        func swiftFiles(_ target: String) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(
                at: root.appending(path: "Sources/\(target)"), includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "swift" }
        }
        for target in ["OpenCineCore", "OpenCineMedia", "OpenCineMotion", "OpenCineRelay", "OpenCineFrameIO"] {
            for file in try swiftFiles(target) {
                let text = try String(contentsOf: file, encoding: .utf8)
                #expect(!text.contains("import OpenCineApple"), "\(target) depends on OpenCineApple")
                #expect(!text.contains("import VideoToolbox") && !text.contains("import AVFoundation"),
                    "\(file.lastPathComponent) imports an OS media framework")
            }
        }
        let files = try swiftFiles("OpenCineApple")
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let first = text.split(separator: "\n").first.map(String.init) ?? ""
            #expect(first.hasPrefix("#if canImport(") || first.hasPrefix("#if os("),
                "\(file.lastPathComponent) is not gated to its platform")
            #expect(text.firstMatch(of: brands) == nil, "\(file.lastPathComponent) names a brand")
            #expect(!text.contains("\u{2014}"), "\(file.lastPathComponent) has an em dash")
        }
    }
}
