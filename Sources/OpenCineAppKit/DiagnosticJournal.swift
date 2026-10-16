import Foundation
import OpenCineMedia
import os

/// Structured lines for the agent loop and the shared report: os.Logger plus a capped journal
/// file, read back by the report (`recentLines`). The app keeps one, with its log subsystem.
///
/// Redaction, os_log and journal writes ride a utility queue: `line` never runs regexes or file
/// I/O on the caller's thread (a socket queue pumping acknowledgements, or Main). Person
/// identifiers are stripped (the host's `redact`) before a line is stored.
///
/// `cap` bounds the file in lines on the trim cadence (Kotlin twin: `DiagnosticJournal(cap)`):
/// the default keeps the report's journal size; a host journal of closed events or a connect
/// trace passes its own smaller bound.
public final class DiagnosticJournal: @unchecked Sendable {
    private let log: Logger
    private let queue = DispatchQueue(label: "opv.control-log", qos: .utility)
    private let cap: Int
    /// Trim cadence in appends, not a size stat per line.
    private let trimEvery = 128
    private let url: URL?
    private let redact: @Sendable (String) -> String
    // Queue-confined.
    private var appendsSinceTrim = 0
    /// Held open between trims instead of an exists/open/seek/close per line.
    private var handle: FileHandle?
    private let stamper = ISO8601DateFormatter()

    public init(
        subsystem: String, category: String, file: URL?,
        cap: Int = DiagnosticReport.journalCap,
        redact: @escaping @Sendable (String) -> String
    ) {
        log = Logger(subsystem: subsystem, category: category)
        url = file
        self.cap = max(1, cap)
        self.redact = redact
    }

    public func line(_ text: String) {
        appendRedacted(text)
    }

    /// Already-redacted structured line (exceptions, diagnostics events).
    /// `logNow` writes os_log on the caller first, for a process about to abort; that line is
    /// redacted too, since os_log keeps it public.
    public func appendRedacted(_ text: String, logNow: Bool = false) {
        let stampedAt = Date()
        if logNow { log.info("\(self.redact(text), privacy: .public)") }
        queue.async { [self] in
            let safe = redact(text)
            if !logNow { log.info("\(safe, privacy: .public)") }
            append(stampedAt, safe)
        }
    }

    public func recentLines() -> [String] {
        queue.sync {
            guard let url else { return [] }
            guard let existing = try? String(contentsOf: url, encoding: .utf8) else {
                return []
            }
            return existing.split(whereSeparator: \.isNewline).map(String.init)
        }
    }

    private func append(_ date: Date, _ text: String) {
        guard let url else { return }
        let row = Data("\(stamper.string(from: date)) \(text)\n".utf8)
        if handle == nil {
            guard FileManager.default.fileExists(atPath: url.path) else {
                try? row.write(to: url)
                return
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        if (try? handle?.write(contentsOf: row)) == nil { closeHandle() }
        appendsSinceTrim += 1
        if appendsSinceTrim >= trimEvery {
            appendsSinceTrim = 0
            // Trim replaces the file; reopen afterwards (also recovers a removed journal).
            closeHandle()
            trimIfNeeded(url)
        }
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    /// Read/rewrite only on the trim cadence, never per send/ack line.
    private func trimIfNeeded(_ url: URL) {
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = existing.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count > cap else { return }
        lines = Array(lines.suffix(cap))
        try? (lines.joined(separator: "\n") + "\n").write(
            to: url, atomically: true, encoding: .utf8)
    }
}
