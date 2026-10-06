import Foundation
import Testing

/// Shared UI decides from capabilities, never from the brand or app it runs in (AGENTS.md,
/// "Capability, not brand"). These rules scan the shared UI and app shell sources on both
/// platforms; the Kotlin mirror is `SharedUIRulesTest` in `Android/monitor-ui`.
struct SharedUIRulesTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Brand, product and app names. camelCase is split first, so `isNano` and `OpenPocketCine`
    /// are caught too.
    static var names: Regex<AnyRegexOutput> {
        try! Regex(
            #"\b(dji|osmo|ronin|nikon|zcine|insta360|insta|luna|pocket|nano|atto|sony|canon|blackmagic|gopro|frame[ .]?io)\b"#
        ).ignoresCase()
    }

    /// Process-wide mutable state a brand or app could switch on. Each entry needs a reason: the
    /// brand accent (a theme value) and display headroom (phone state, not brand). The set must
    /// match exactly, so removing a global also removes it here.
    static let allowedGlobals: Set<String> = ["MonitorTheme.accentRGB", "MonitorTheme.hdrGain"]

    /// The shared UI, the app shell and the camera controls.
    static let shared = [
        "Sources/MonitorUI", "Sources/MonitorPresentation", "Sources/OpenCineAppKit", "Sources/OpenCineAppKitApple",
        "Sources/OpenCineCameraControls",
    ]

    static func sources(_ directories: [String], extensions: Set<String>) throws -> [URL] {
        try directories.flatMap { directory -> [URL] in
            let base = root.appending(path: directory)
            let walker = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            return walker.compactMap { $0 as? URL }.filter { extensions.contains($0.pathExtension) }
        }
    }

    static func splitCamelCase(_ text: String) -> String {
        text.replacing(#/([a-z0-9])([A-Z])/#) { "\($0.1) \($0.2)" }
    }

    /// Stored `static var`s, `nonisolated(unsafe)` declarations and file-scope `var`s, named
    /// `Type.name` by the innermost enclosing type. Line-based: comments and string literals are
    /// dropped first.
    static func mutableGlobals(in text: String) -> [String] {
        let storedStatic = #/\bstatic\s+var\s+(\w+)\s*(?::[^{=]*)?(?:=|$)/#
        let unsafe = #/nonisolated\(unsafe\)[^=:]*\b(?:var|let)\s+(\w+)/#
        let fileScope = #/^(?:@\w+\s+)*(?:(?:public|internal|private|fileprivate)\s+)?var\s+(\w+)/#
        let typeName = #/\b(?:enum|struct|class|actor|extension)\s+(\w+)[^{]*$/#
        var scopes: [String?] = []
        var found: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw).replacing(#/"(?:\\.|[^"\\])*"/#, with: "\"\"")
            if let comment = line.range(of: "//") { line = String(line[..<comment.lowerBound]) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let owner = scopes.compactMap { $0 }.last.map { "\($0)." } ?? ""
            for name in [
                trimmed.firstMatch(of: storedStatic)?.1, trimmed.firstMatch(of: unsafe)?.1,
                scopes.isEmpty ? trimmed.firstMatch(of: fileScope)?.1 : nil,
            ].compactMap({ $0 }) {
                found.append(owner + name)
            }
            var prefix = ""
            for character in line {
                if character == "{" {
                    scopes.append(prefix.firstMatch(of: typeName).map { String($0.1) })
                } else if character == "}" {
                    _ = scopes.popLast()
                }
                prefix.append(character)
            }
        }
        return Array(Set(found)).sorted()
    }

    @Test func sharedUINamesNoBrandProductOrApp() throws {
        #expect(Self.splitCamelCase("isNanoBody").firstMatch(of: Self.names) != nil)
        #expect("Built for OpenPocketCine".firstMatch(of: Self.names) == nil)
        #expect(Self.splitCamelCase("Built for OpenPocketCine").firstMatch(of: Self.names) != nil)
        #expect(Self.splitCamelCase("one instance, nanoseconds").firstMatch(of: Self.names) == nil)
        let files = try Self.sources(Self.shared, extensions: ["swift"])
        #expect(files.count > 20)
        for file in files {
            let text = Self.splitCamelCase(try String(contentsOf: file, encoding: .utf8))
            let match = text.firstMatch(of: Self.names).map { String(text[$0.range]) }
            #expect(match == nil, "\(file.lastPathComponent) names \(match ?? "")")
        }
    }

    @Test func sharedUIHasNoMutableGlobalsOutsideTheAllowlist() throws {
        let sample = """
            var counter = 0
            enum Theme {
                nonisolated(unsafe) public static var accent: UInt32 = 1 // "{"
                public static var text: Color { color(accent) }
                @MainActor static var shown = false
                static let fixed = 1
                func draw() { var local = 0; local += 1 }
            }
            struct Card { var title: String; static var defaultValue: CGFloat { 0 } }
            """
        #expect(Self.mutableGlobals(in: sample) == ["Theme.accent", "Theme.shown", "counter"])
        let files = try Self.sources(Self.shared, extensions: ["swift"])
        var found: Set<String> = []
        for file in files {
            found.formUnion(Self.mutableGlobals(in: try String(contentsOf: file, encoding: .utf8)))
        }
        #expect(found == Self.allowedGlobals)
    }

    @Test func nativeViewsImportOnlyPresentationMediaAndSystemFrameworks() throws {
        let allowed: Set = ["Foundation", "SwiftUI", "UIKit", "CoreGraphics", "CoreImage",
            "CoreText", "Metal", "MetalKit", "MetalPerformanceShaders", "os",
            "MonitorPresentation", "OpenCineMedia"]
        for file in try Self.sources(["Sources/MonitorUI"], extensions: ["swift"]) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") {
                let words = line.split(separator: " ").map(String.init)
                guard let index = words.firstIndex(of: "import"), index + 1 < words.count,
                    words[..<index].allSatisfy({ $0.hasPrefix("@") }) else { continue }
                #expect(allowed.contains(words[index + 1]), "\(file.lastPathComponent): \(line)")
            }
            #expect(!source.contains("OpenCineApple"), "\(file.lastPathComponent) reaches a native owner")
        }
    }
}
