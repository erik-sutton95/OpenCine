import Foundation
import OpenCineGyro
import Testing

@testable import OpenCineCameraControls

@Suite struct GyroLogSectionsTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0)
        -> Date
    {
        calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone, year: year, month: month, day: day, hour: hour,
                minute: minute))!
    }

    private static func entry(_ start: Date) -> GyroLogEntry {
        GyroLogEntry(
            descriptor: GyroLogDescriptor(
                appName: "Test", cameraLabel: "Camera", startDate: start,
                approximateStartOffset: 0, isPartial: false),
            summary: nil, active: false)
    }

    private static let now = date(2026, 10, 25, 15)

    @Test func groupsTodayYesterdayAndDates() {
        let entries = [
            Self.entry(Self.date(2026, 10, 25, 14, 18)),
            Self.entry(Self.date(2026, 10, 25, 9)),
            Self.entry(Self.date(2026, 10, 24, 19, 2)),
            Self.entry(Self.date(2026, 10, 12, 8)),
            Self.entry(Self.date(2025, 3, 3, 8)),
        ]
        let sections = GyroLogSections.group(entries, now: Self.now, calendar: Self.calendar)
        #expect(sections.count == 4)
        #expect(sections[0].title == GyroCopy.today)
        #expect(sections[0].entries.count == 2)
        #expect(sections[1].title == GyroCopy.yesterday)
        #expect(sections[2].title.contains("Monday"))
        #expect(sections[2].title.contains("12"))
        #expect(!sections[2].title.contains("2026"))
        #expect(sections[3].title.contains("2025"))
    }

    @Test func ordersNewestFirst() {
        let early = Self.entry(Self.date(2026, 10, 25, 9))
        let late = Self.entry(Self.date(2026, 10, 25, 14))
        let older = Self.entry(Self.date(2026, 10, 24, 20))
        let sections = GyroLogSections.group(
            [older, early, late], now: Self.now, calendar: Self.calendar)
        #expect(sections.flatMap(\.entries).map(\.id) == [late.id, early.id, older.id])
        #expect(GyroLogSections.group([], now: Self.now, calendar: Self.calendar).isEmpty)
    }

    @Test func rowSubtitleJoinsCameraAndLength() {
        let recording = GyroLogEntry(
            descriptor: Self.entry(Self.now.addingTimeInterval(-12)).descriptor, summary: nil,
            active: true)
        #expect(recording.rowSubtitle(now: Self.now) == "Camera\(GyroCopy.separator)0:12")
        #expect(Self.entry(Self.now).rowSubtitle(now: Self.now) == "Camera")
    }
}
