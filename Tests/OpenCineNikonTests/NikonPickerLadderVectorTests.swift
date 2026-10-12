import Foundation
import Testing

@testable import OpenCineNikon

/// The Swift half of `Fixtures/nikon-picker-ladders.tsv`. Kotlin re-implements the same ladders in
/// `Android/nikon` and reads the same rows, so a ladder edited on one side only fails a test.
@Suite struct NikonPickerLadderVectorTests {
    static let rows: [[String]] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenCineNikonTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let path = root.appendingPathComponent("Fixtures/nikon-picker-ladders.tsv").path
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.components(separatedBy: "\t") }
    }()

    static let ladders: [String: [String]] = [
        "shutter.angle": ShutterPickerPolicy.angleOptions,
        "shutter.speed": ShutterPickerPolicy.speedOptions,
        "focus.afMode": FocusPickerPolicy.afModeOptions,
        "focus.area": FocusPickerPolicy.areaOptions,
        "focus.subject": FocusPickerPolicy.subjectOptions,
        "still.iso": StillPickerLadders.isoOptions,
        "still.shutter": StillPickerLadders.shutterOptions,
        "still.iris": StillPickerLadders.irisOptions,
        "still.drive": StillPickerLadders.driveOptions,
        "still.appTimer": StillPickerLadders.appTimerOptions,
        "still.focusMode": StillPickerLadders.focusModeOptions,
        "still.focusArea": StillPickerLadders.focusAreaOptions,
        "still.focusSubject": StillPickerLadders.focusSubjectOptions,
        "still.mode": StillPickerLadders.modeOptions,
        "still.userMode": StillPickerLadders.userModeOptions,
        "still.meter": StillPickerLadders.meterOptions,
        "still.picture": StillPickerLadders.pictureOptions,
        "still.area": StillPickerLadders.areaOptions,
        "still.size": StillPickerLadders.sizeOptions,
        "still.quality": StillPickerLadders.qualityOptions,
        "still.nef": StillPickerLadders.nefOptions,
    ]

    static let bases: [String: String] = [
        "shutter.angle": ShutterPickerPolicy.angleBase,
        "shutter.speed": ShutterPickerPolicy.speedBase,
        "focus.afMode": FocusPickerPolicy.afModeBase,
        "focus.area": FocusPickerPolicy.areaBase,
        "focus.subject": FocusPickerPolicy.subjectBase,
    ]

    @Test func everyLadderMatchesTheFixture() {
        let fixture = Self.rows.filter { $0[0] == "ladder" }
        #expect(
            Set(fixture.map { $0[1] }) == Set(Self.ladders.keys),
            "fixture missing or a ladder unshared")
        for row in fixture {
            #expect(Self.ladders[row[1]] == Array(row.dropFirst(2)), "\(row[1])")
        }
    }

    @Test func everyBaseMatchesTheFixture() {
        let fixture = Self.rows.filter { $0[0] == "base" }
        #expect(Set(fixture.map { $0[1] }) == Set(Self.bases.keys))
        for row in fixture {
            #expect(Self.bases[row[1]] == row[2], "\(row[1])")
            #expect(
                Self.ladders[row[1]]?.contains(row[2]) == true, "\(row[1]) base is off its ladder")
        }
    }

    @Test func tintLabelsMatchTheFixture() {
        let fixture = Self.rows.filter { $0[0] == "tint" }
        #expect(fixture.count >= 10)
        for row in fixture {
            let label = WhiteBalanceTint.label(
                amberBlueCell: Int(row[1])!, greenMagentaCell: Int(row[2])!)
            #expect(label == row[3], "\(row[1]),\(row[2])")
        }
    }
}
