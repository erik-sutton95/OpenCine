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

    @Test func everyKotlinMemberMatchesTheExportParameterCount() throws {
        let exported = try Self.parameterCountsByExport(
            in: String(contentsOf: Self.sourceFile(), encoding: .utf8))
        let declared = try Self.parameterCountsByKotlinMember(
            in: String(contentsOf: Self.kotlinFile(), encoding: .utf8))
        #expect(exported.count == Self.names.count)
        #expect(declared.count == Self.names.count)
        #expect(Set(exported.keys) == Set(declared.keys))
        for (name, count) in exported {
            #expect(declared[name] == count - 2, "\(name): JNI env and receiver are implicit")
        }
    }

    private static func sourceFile() -> URL {
        repositoryRoot.appending(path: "Sources/OpenCineGyroAndroid/GyroNativeJNI.swift")
    }

    private static func kotlinFile() -> URL {
        repositoryRoot.appending(
            path: "Android/gyro/src/main/kotlin/com/opencapture/opencine/gyro/GyroNative.kt")
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func parameterCountsByExport(in text: String) throws -> [String: Int] {
        let regex = try NSRegularExpression(
            pattern:
                #"@_cdecl\("Java_com_opencapture_opencine_gyro_GyroNative_([A-Za-z0-9_]+)"\)\s*public\s+func\s+[A-Za-z0-9_]+\("#
        )
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var counts: [String: Int] = [:]
        for match in regex.matches(in: text, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text),
                let openParen = Range(match.range, in: text)
            else { continue }
            counts[String(text[nameRange])] = parameterCount(
                in: text, startingAfter: openParen.upperBound)
        }
        return counts
    }

    private static func parameterCountsByKotlinMember(in text: String) throws -> [String: Int] {
        let regex = try NSRegularExpression(
            pattern: #"external\s+override\s+fun\s+([A-Za-z0-9_]+)\s*\("#)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var counts: [String: Int] = [:]
        for match in regex.matches(in: text, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: text),
                let openParen = Range(match.range, in: text)
            else { continue }
            counts[String(text[nameRange])] = parameterCount(
                in: text, startingAfter: openParen.upperBound)
        }
        return counts
    }

    /// Counts top-level parameters up to the matching closing parenthesis, so line breaks and
    /// trailing commas do not change the result.
    private static func parameterCount(in text: String, startingAfter start: String.Index) -> Int {
        var parameters: [String] = []
        var current = ""
        var depth = 0
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == "(" {
                depth += 1
                current.append(character)
            } else if character == ")" {
                if depth == 0 { break }
                depth -= 1
                current.append(character)
            } else if character == ",", depth == 0 {
                parameters.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = text.index(after: index)
        }
        parameters.append(current)
        return parameters.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
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
