import Foundation
import Testing

/// MEDIA-01 gate: shared media math imports only Foundation and OpenCineCore (it also builds for
/// Android; LiveFrameTap's Apple imports are gated),
/// takes no camera raw mode, and holds no mutable global preference or calibration. Ceilings,
/// look curves and readings arrive as parameters from the integration that owns them.
@Suite struct MediaSourceRulesTests {
    @Test func mediaImportsOnlyFoundationAndHoldsNoGlobalState() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appending(path: "Sources/OpenCineMedia")
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            // LiveFrameTap is the one Apple-only helper; its imports sit behind
            // `#if canImport(CoreVideo)` so Android builds skip it.
            let allowed: Set<String> =
                file.lastPathComponent == "LiveFrameTap.swift"
                ? ["import Foundation", "import CoreVideo", "import CoreGraphics", "@preconcurrency import CoreImage"]
                : ["import Foundation", "import OpenCineCore"]
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("import ") || line.hasPrefix("@preconcurrency import ") else { continue }
                #expect(allowed.contains(line), "\(file.lastPathComponent): \(line)")
            }
            #expect(!text.contains("static var"), "\(file.lastPathComponent) has mutable static state")
            #expect(!text.contains("nonisolated(unsafe)"), "\(file.lastPathComponent)")
            #expect(!text.contains("ColorMode"), "\(file.lastPathComponent) takes a camera raw mode")
        }
    }
}
