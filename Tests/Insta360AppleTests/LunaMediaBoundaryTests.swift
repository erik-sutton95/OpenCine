import Foundation
import Testing

@Suite struct LunaMediaBoundaryTests {
    @Test func sourceProducerImportsOnlyItsProtocolAndNeutralContracts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/Insta360Apple/LunaMediaService.swift"), encoding: .utf8)
        let imports = source.split(separator: "\n").filter { $0.hasPrefix("import ") }.map(String.init)
        #expect(Set(imports) == ["import Foundation", "import Insta360Protocol",
            "import OpenCineCore", "import OpenCineMedia"])
        for forbidden in ["OpenCineApple", "MonitorUI", "OpenCineAppKit", "UserDefaults", "static var"] {
            #expect(!source.contains(forbidden), "Media source acquired a higher owner: \(forbidden)")
        }
    }
}
