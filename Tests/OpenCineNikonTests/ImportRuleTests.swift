import Foundation
import Testing

/// The package stays UI-free and app-free: sources import Foundation, OpenCineCore, neutral OpenCineMedia products,
/// the camera vocabulary (its session recovery) and the gyro camera contract only (plan VENDOR-02: no UI, no app types).
/// The Apple transports (SHELL-04) may also import Darwin, os and ImageCaptureCore, inside a file-wide `#if` so the
/// Android build compiles them out.
@Suite struct ImportRuleTests {
    @Test func sourcesImportOnlyFoundationAndOpenCineCore() throws {
        let allowed: Set = ["Foundation", "OpenCineCore", "OpenCineMedia", "OpenCineCameraVocabulary", "OpenCineGyro"]
        let platformOnly: Set = ["Darwin", "os", "ImageCaptureCore"]
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenCineNikon")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for line in text.split(separator: "\n") {
                let words = line.split(separator: " ").map(String.init)
                guard let index = words.firstIndex(of: "import"), index + 1 < words.count,
                    words[..<index].allSatisfy({ $0.hasPrefix("@") })
                else { continue }
                let module = words[index + 1]
                if platformOnly.contains(module) {
                    #expect(text.hasPrefix("#if "), "\(file): \(module) outside a file-wide #if")
                } else {
                    #expect(allowed.contains(module), "\(file): \(line)")
                }
            }
        }
    }

    @Test func nativeIdentityIsAvailableToAndroidSwift() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenCineNikon/NativeCameraIdentity.swift")
        guard FileManager.default.fileExists(atPath: source.path) else {
            #expect(Bool(false), "NativeCameraIdentity must live outside the Apple-only session file")
            return
        }
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(!text.hasPrefix("#if "), "NativeCameraIdentity must compile on Android Swift")
    }
}
