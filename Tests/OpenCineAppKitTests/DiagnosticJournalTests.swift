import Foundation
import OpenCineAppKit
import OpenCineMedia
import Testing
import os

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

    /// A host journal with a smaller bound (Z's closed events and connect trace) trims to its own
    /// cap on the same cadence, like the Kotlin twin's `DiagnosticJournal(cap)`.
    @Test func hostCapBoundsTheJournal() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("journal-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        let journal = DiagnosticJournal(
            subsystem: "com.opencapture.test", category: "events", file: file, cap: 10,
            redact: { $0 })
        for index in 0..<140 { journal.line("line \(index)") }
        let lines = journal.recentLines()
        // The first line creates the file; the 128th append after it trims to the last 10
        // (119 to 128), and the last 11 follow.
        #expect(lines.count == 21)
        #expect(lines.first?.hasSuffix(" line 119") == true)
        #expect(lines.last?.hasSuffix(" line 139") == true)
    }

    /// The immediate os_log line of a process about to abort is redacted as well as the stored one.
    @Test func immediateLogLineIsRedactedToo() {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let journal = DiagnosticJournal(
            subsystem: "com.opencapture.test", category: "session", file: nil,
            redact: { text in
                calls.withLock { count in count += 1 }
                return PrivacyRedactor.redact(text)
            })
        journal.appendRedacted("fault tester@example.com", logNow: true)
        _ = journal.recentLines()  // waits for the queued write
        #expect(calls.withLock { count in count } == 2)
    }
}
