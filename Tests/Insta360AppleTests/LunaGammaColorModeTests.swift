import Foundation
import Insta360Apple
import Insta360Protocol
import Testing

/// Gamma metadata has one integration owner so catalog and playback cannot drift.
@Suite struct LunaGammaColorModeTests {
    @Test func recognizedMetadataPreservesExistingAliasesAndPriority() {
        let cases: [(String, LunaColorMode)] = [
            ("I-Log", .iLog), ("ilog", .iLog), ("LOG HDR", .iLog),
            ("Dolby Vision", .dolbyVision), ("DOLBY", .dolbyVision), ("HDR", .dolbyVision),
            ("hdr standard", .dolbyVision), ("Standard", .standard), ("STANDARD", .standard),
            ("VIVID", .vivid), ("vivid", .vivid), ("standard vivid", .standard),
        ]
        for (label, expected) in cases {
            #expect(LunaColorMode(gammaLabel: label) == expected, "Metadata: \(label)")
        }
    }

    @Test func missingOrUnknownMetadataStaysUnknown() {
        for label: String? in [nil, "", " ", "flat", "unknown", "rec709"] {
            #expect(LunaColorMode(gammaLabel: label) == nil)
        }
    }

    #if os(macOS)
    @Test func gammaMetadataHasOneIntegrationOwner() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let integration = try String(
            contentsOf: root.appending(path: "Sources/Insta360Apple/LunaMediaService.swift"),
            encoding: .utf8)
        #expect(integration.contains("init?(gammaLabel: String?)"),
            "The integration supplies the metadata mapping to its consumers")

        // The integration remains testable alone; an owned multi-repository gate also checks adopters.
        guard let adopterRoot = ProcessInfo.processInfo.environment["OPENCINE_LUNA_ADOPTION_SOURCE_ROOT"] else { return }
        let app = URL(fileURLWithPath: adopterRoot)
        for name in ["LunaMediaCatalogCodec.swift", "LunaPlaybackComposition.swift"] {
            let source = try String(contentsOf: app.appending(path: name), encoding: .utf8)
            #expect(source.contains("LunaColorMode(gammaLabel:"), "\(name) adopts the integration mapping")
            #expect(!source.contains("gamma.contains("), "\(name) keeps no second gamma interpretation")
        }
    }
    #endif
}
