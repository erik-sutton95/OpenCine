import Foundation
import OpenCineAppKit
import OpenCineMedia
import Testing

/// The journal that was each app's ControlLiveLog: redacted lines, capped on the trim cadence.
@Suite struct DiagnosticJournalTests {
    @Test func storesRedactedLinesAndTrimsToTheCap() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        let journal = DiagnosticJournal(
            subsystem: "com.opencapture.test", category: "session", file: file,
            redact: { PrivacyRedactor.redact($0) })
        journal.line("send tester@example.com")
        #expect(journal.recentLines().count == 1)
        #expect(journal.recentLines()[0].hasSuffix(" send <email>"))
        for index in 1..<2_600 { journal.line("line \(index)") }
        let lines = journal.recentLines()
        // The first line creates the file; the 2560th append after it trims 2561 lines to the
        // cap (2500), and the last 39 follow.
        #expect(lines.count == DiagnosticReport.journalCap + 39)
        #expect(lines.last?.hasSuffix(" line 2599") == true)
        #expect(!lines.contains { $0.contains("tester@example.com") })
    }
}
