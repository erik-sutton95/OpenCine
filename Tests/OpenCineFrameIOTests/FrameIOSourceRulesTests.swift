import Foundation
import Testing

/// OPTIONAL-01 gate: the delivery product carries no package dependency, holds no global mutable
/// state and names no app credential namespace; the minimum Core products never import it.
@Suite struct FrameIOSourceRulesTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func swiftFiles(_ directory: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root.appending(path: directory), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
    }

    @Test func frameIOImportsOnlyFoundationAndCryptoKitAndNamesNoApp() throws {
        let files = try Self.swiftFiles("Sources/OpenCineFrameIO")
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("import ") else { continue }
                #expect(
                    ["import Foundation", "import CryptoKit"].contains(line),
                    "\(file.lastPathComponent): \(line)")
            }
            #expect(!text.contains("static var"), "\(file.lastPathComponent) has mutable static state")
            #expect(!text.contains("nonisolated(unsafe)"), "\(file.lastPathComponent)")
            // Keychain services, defaults keys and bundle lookups belong to each app.
            for appOwned in ["OpenPocketCine", "OpenZCine", "OpenInstaCine", "kSec", "UserDefaults", "Bundle.main"] {
                #expect(!text.contains(appOwned), "\(file.lastPathComponent) names \(appOwned)")
            }
        }
    }

    @Test func minimumCoreProductsNeverImportDelivery() throws {
        for directory in ["Sources/OpenCineCore", "Sources/OpenCineMedia"] {
            for file in try Self.swiftFiles(directory) {
                let text = try String(contentsOf: file, encoding: .utf8)
                #expect(!text.contains("OpenCineFrameIO"), "\(file.lastPathComponent)")
            }
        }
    }
}

/// Frame.io's Apple host (A2-57) takes every namespace from the app: it names no app and holds
/// no global state; it builds only on the Frame.io client and the app shell.
@Suite struct FrameIOAppleSourceRulesTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func frameIOAppleImportsOnlyTheClientTheAppShellAndSystemFrameworks() throws {
        let allowed: Set<String> = [
            "Foundation", "Observation", "SwiftUI", "UIKit", "AuthenticationServices", "Security",
            "OpenCineFrameIO", "OpenCineAppKit", "OpenCineAppKitApple",
        ]
        let files = try FileManager.default.contentsOfDirectory(
            at: Self.root.appending(path: "Sources/OpenCineFrameIOApple"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("import ") else { continue }
                #expect(allowed.contains(String(line.dropFirst("import ".count))), "\(file.lastPathComponent): \(line)")
            }
            #expect(!text.contains("static var"), "\(file.lastPathComponent) has mutable static state")
            #expect(!text.contains("nonisolated(unsafe)"), "\(file.lastPathComponent)")
            // The host reads its app's Info.plist by design, but never names an app.
            for appOwned in ["OpenPocketCine", "OpenZCine", "OpenInstaCine"] {
                #expect(!text.contains(appOwned), "\(file.lastPathComponent) names \(appOwned)")
            }
        }
    }
}
