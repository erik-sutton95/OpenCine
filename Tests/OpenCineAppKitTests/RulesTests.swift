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
            // The problem report form attaches photos and screenshots (system PhotosUI).
            "PhotosUI",
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

    /// The Apple composition layer sits above the app shell and the Apple runtimes only: never an
    /// integration, an app or a third-party package.
    @Test func appKitAppleImportsOnlyTheAppShellAndAppleLayers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let package: Set<String> = [
            "OpenCineAppKit", "MonitorUI", "MonitorPresentation", "OpenCineApple", "OpenCineMedia", "OpenCineMotion",
            "OpenCineRelay", "OpenCineRelayApple",
        ]
        let system: Set<String> = [
            "Foundation", "Observation", "Network", "SwiftUI", "UIKit", "CoreMotion", "CoreImage.CIFilterBuiltins", "os",
            "Metal", "MetalKit", "QuartzCore", "AVFoundation", "Photos",
            // The delivery share sheet's typed file items.
            "LinkPresentation", "UniformTypeIdentifiers",
            // The remote shutter's volume view, which hides the system volume overlay (A2-32).
            "MediaPlayer",
        ]
        let directory = root.appending(path: "Sources/OpenCineAppKitApple")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
            where line.hasPrefix("import ") {
                let module = String(line.dropFirst("import ".count))
                #expect(package.contains(module) || system.contains(module), "\(file.lastPathComponent): \(line)")
            }
        }
        let manifest = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        let target = try #require(
            manifest.firstMatch(of: #/\.target\(\s*name: "OpenCineAppKitApple",\s*dependencies: \[([^\]]*)\]/#))
        let dependencies = target.1.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: ["\""]) }
        #expect(!dependencies.isEmpty && Set(dependencies).isSubset(of: package))
    }

    /// The reporting adapter is optional and its own package (`Packages/OpenCineSentryApple`), so
    /// the OpenCine package names no third-party package and no OpenCine module imports the SDK or
    /// the adapter (Kotlin: `AdapterIsolationTest` in `appkit-sentry`).
    @Test func sentryAdapterStaysOutOfThePackageGraph() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        #expect(!manifest.contains(".package("))
        let adapter = try String(
            contentsOf: root.appending(path: "Packages/OpenCineSentryApple/Package.swift"), encoding: .utf8)
        #expect(adapter.contains(#".package(url: "https://github.com/getsentry/sentry-cocoa", exact: "#))
        for directory in ["Sources", "Tests"] {
            let files = (FileManager.default.enumerator(
                at: root.appending(path: directory), includingPropertiesForKeys: nil)?
                .allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                for line in text.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    #expect(line != "import Sentry" && line != "import OpenCineSentryApple", "\(file.lastPathComponent)")
                }
            }
        }
    }

    /// Camera controls are app composition over the camera vocabulary: never OpenCineDJI or another
    /// integration, an app or a third-party package (AGENTS.md, camera controls).
    @Test func cameraControlsImportOnlyTheVocabularyAppShellAndUI() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let package: Set<String> = [
            "OpenCineCameraVocabulary", "MonitorUI", "MonitorPresentation", "OpenCineAppKit",
            "OpenCineAppKitApple", "OpenCineCore", "OpenCineMedia", "OpenCineMotion",
            // The shared clip delivery exports through the Apple media exporter.
            "OpenCineApple",
            // The shared gyro screens and their coordinator binding.
            "OpenCineGyro", "OpenCineGyroApple",
        ]
        let system: Set<String> = [
            "CoreHaptics", "CoreVideo", "Foundation", "GameController", "Observation", "SwiftUI", "UIKit",
            "UniformTypeIdentifiers", "Vision",
            // Scope plots accept portable Media values and configure the system MTKView.
            "MetalKit",
        ]
        let directory = root.appending(path: "Sources/OpenCineCameraControls")
        let files = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let words = line.split(separator: " ").map(String.init)
                guard let index = words.firstIndex(of: "import"), index + 1 < words.count,
                    words[..<index].allSatisfy({ $0.hasPrefix("@") })
                else { continue }
                let module = words[index + 1]
                #expect(package.contains(module) || system.contains(module), "\(file.lastPathComponent): \(line)")
            }
        }
        let manifest = try String(contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        let target = try #require(
            manifest.firstMatch(of: #/\.target\(\s*name: "OpenCineCameraControls",\s*dependencies: \[([^\]]*)\]/#))
        let dependencies = target.1.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: ["\""]) }
            .filter { !$0.isEmpty }
        #expect(!dependencies.isEmpty && Set(dependencies).isSubset(of: package))
    }
}
