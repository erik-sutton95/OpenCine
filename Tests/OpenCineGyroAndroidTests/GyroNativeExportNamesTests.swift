import Foundation
import Testing

@testable import OpenCineGyroAndroid

/// Guards the JNI file the macOS host never compiles (`#if os(Android)`): its exported symbol
/// names are the native contract the Kotlin class `com.opencapture.opencine.gyro.GyroNative`
/// declares as `external fun`.
@Suite("Android gyro native export names")
struct GyroNativeExportNamesTests {
    private static let prefix = "Java_com_opencapture_opencine_gyro_GyroNative_"

    /// Every export the shared native contract lists, in the order the plan names them.
    private static let names = [
        "loggingCreate", "loggingIngest", "loggingObserve", "loggingMountMoved", "loggingPoll",
        "loggingFinish", "loggingClose",
        "recoveryCreate", "recoveryAccept", "recoveryFinish",
        "ringCreate", "ringStart", "ringUpdateCamera", "ringObserve", "ringInvalidate",
        "ringCancel", "ringClose", "calibrationValidate",
        "driftCreate", "driftObserveCamera", "driftObservePhone", "driftReset", "driftClose",
        "armingCreate", "armingUpdate", "armingChooseTurnOff", "armingChooseKeepOn",
        "armingWriteFinished", "armingClose",
        "cameraDown",
    ]

    @Test func everyExportMatchesTheKotlinNativeContract() throws {
        let text = try String(contentsOf: Self.sourceFile(), encoding: .utf8)
        let exported = try Self.exportedNames(in: text)
        #expect(exported.count == Self.names.count)
        #expect(Set(exported) == Set(Self.names.map { Self.prefix + $0 }))
        #expect(text.contains("#if os(Android)"))
    }

    private static func sourceFile() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/OpenCineGyroAndroid/GyroNativeJNI.swift")
    }

    private static func exportedNames(in text: String) throws -> [String] {
        let regex = try NSRegularExpression(
            pattern: #"@_cdecl\("(Java_com_opencapture_opencine_[A-Za-z0-9_]+)"\)"#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let nameRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[nameRange])
        }
    }
}
