#if os(iOS)
import Foundation
import Testing

/// The iOS gyro shell imports OpenCineGyro and Apple frameworks only and names no app or
/// manufacturer.
@Suite struct GyroAppleSourceRulesTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let allowedImports: Set<String> = [
        "Foundation", "CoreMotion", "UIKit", "Observation", "OpenCineGyro",
    ]
    private static let forbiddenNames = [
        "Nikon", "Canon", "Sony", "DJI", "Insta360", "OpenZCine", "OpenPocketCine",
        "OpenInstaCine",
    ]

    @Test func importsAreGyroAndAppleFrameworksOnly() throws {
        let directory = Self.root.appending(path: "Sources/OpenCineGyroApple")
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("import ") else { continue }
                let module = String(line.dropFirst("import ".count))
                #expect(
                    Self.allowedImports.contains(module),
                    "\(file.lastPathComponent): \(line)")
            }
            let lowered = text.lowercased()
            for name in Self.forbiddenNames {
                #expect(
                    !lowered.contains(name.lowercased()),
                    "\(file.lastPathComponent) names \(name)")
            }
        }
    }
}
#endif
