import Foundation
import Testing

@Suite struct DJIAppleImportRuleTests {
    @Test func nativeTransportImportsOnlyItsDownwardProductsAndSystemFrameworks() throws {
        let allowed: Set = ["Foundation", "CoreBluetooth", "Network", "NetworkExtension", "Darwin", "os",
            "OpenCineCore", "OpenCineDJI", "OpenCineMedia", "OpenCineMotion"]
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenCineDJIApple")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in source.split(separator: "\n") {
                let words = line.split(separator: " ").map(String.init)
                guard let index = words.firstIndex(of: "import"), index + 1 < words.count,
                    words[..<index].allSatisfy({ $0.hasPrefix("@") }) else { continue }
                #expect(allowed.contains(words[index + 1]), "\(file): \(line)")
            }
            for forbidden in ["OpenPocketViewCore", "ControlLiveLog", "StartupConnectionCopy",
                "FeedIncidentRuntime", "CameraWifiKeychain", "WatcherRelayProtocol",
                "FileManager", "FileHandle", "UserDefaults", "ble-gatt.log"] {
                #expect(!source.contains(forbidden), "\(file) imports app policy: \(forbidden)")
            }
            if source.contains("import CoreBluetooth") || source.contains("import NetworkExtension")
                || source.contains("import Network") {
                #expect(source.hasPrefix("#if os(iOS)\n"), "\(file) must resolve outside iOS")
            }
        }
    }
}
