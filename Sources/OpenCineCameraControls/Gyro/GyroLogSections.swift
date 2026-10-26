import Foundation
import OpenCineGyro

/// One day of takes in the logs list.
public struct GyroLogSection: Equatable, Identifiable {
    public let title: String
    public let entries: [GyroLogEntry]

    public var id: String { title }

    public init(title: String, entries: [GyroLogEntry]) {
        self.title = title
        self.entries = entries
    }

    public static func == (lhs: GyroLogSection, rhs: GyroLogSection) -> Bool {
        lhs.title == rhs.title
            && lhs.entries.map { [$0.id.uuidString, GyroCopy.status($0.status)] }
                == rhs.entries.map { [$0.id.uuidString, GyroCopy.status($0.status)] }
    }
}

public enum GyroLogSections {
    /// Takes grouped by calendar day, newest first. Titles are `Today`, `Yesterday`, otherwise
    /// the weekday, month and day (with the year when it is not the current year).
    public static func group(_ entries: [GyroLogEntry], now: Date, calendar: Calendar)
        -> [GyroLogSection]
    {
        let sorted = entries.sorted { $0.descriptor.startDate > $1.descriptor.startDate }
        var sections: [GyroLogSection] = []
        var currentDay: Date?
        var bucket: [GyroLogEntry] = []
        func flush() {
            guard let day = currentDay, !bucket.isEmpty else { return }
            sections.append(
                GyroLogSection(title: title(for: day, now: now, calendar: calendar), entries: bucket))
            bucket = []
        }
        for entry in sorted {
            let day = calendar.startOfDay(for: entry.descriptor.startDate)
            if day != currentDay {
                flush()
                currentDay = day
            }
            bucket.append(entry)
        }
        flush()
        return sections
    }

    static func title(for day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return GyroCopy.today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(day, inSameDayAs: yesterday)
        {
            return GyroCopy.yesterday
        }
        var style = Date.FormatStyle(
            locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar,
            timeZone: calendar.timeZone
        )
        .weekday(.wide).month().day()
        if !calendar.isDate(day, equalTo: now, toGranularity: .year) { style = style.year() }
        return day.formatted(style)
    }
}

extension GyroLogEntry {
    /// The take's length: the finished summary, else the time since a recording take began.
    func length(now: Date) -> Double? {
        if let summary { return summary.duration }
        return active ? max(0, now.timeIntervalSince(descriptor.startDate)) : nil
    }

    /// `camera · length`, without the length when none is known yet.
    func rowSubtitle(now: Date) -> String {
        var parts = [descriptor.cameraLabel]
        if let seconds = length(now: now) { parts.append(GyroCopy.length(seconds)) }
        return parts.joined(separator: GyroCopy.separator)
    }
}
