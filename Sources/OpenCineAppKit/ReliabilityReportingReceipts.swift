import Foundation

// Per-incident delivery receipts of the apps' crash and incident reporting: queued when the SDK
// accepts an event, confirmed when its envelope upload succeeds, kept as one JSON file per
// incident under `root/receipts` for a week. Kotlin: `ReliabilityReportingReceipts` in
// `appkit/diagnostics/ReliabilityReportingPrivacy.kt`.

public enum ReliabilityReportingReceiptState: String, Equatable, Sendable, Codable {
    case queued
    case confirmed
}

public struct ReliabilityReportingReceipt: Equatable, Sendable, Codable {
    public var incidentID: String
    public var eventID: String
    public var state: ReliabilityReportingReceiptState
    public var updatedAt: Date

    public init(
        incidentID: String, eventID: String, state: ReliabilityReportingReceiptState, updatedAt: Date
    ) {
        self.incidentID = incidentID
        self.eventID = eventID
        self.state = state
        self.updatedAt = updatedAt
    }
}

public enum ReliabilityReportingReceipts {
    public static func directory(root: URL) -> URL {
        root.appendingPathComponent("receipts", isDirectory: true)
    }

    /// The receipt file of `incidentID`, or nil for an ID that could name a file outside the
    /// receipts directory (a path separator or `..`).
    public static func file(incidentID: String, root: URL) -> URL? {
        guard !incidentID.contains("/"), !incidentID.contains("\\"), !incidentID.contains("..")
        else { return nil }
        return directory(root: root).appendingPathComponent("\(incidentID).json")
    }

    public static func load(incidentID: String, root: URL) -> ReliabilityReportingReceipt? {
        guard let url = file(incidentID: incidentID, root: root),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(ReliabilityReportingReceipt.self, from: data)
    }

    public static func store(_ receipt: ReliabilityReportingReceipt, root: URL) {
        guard let url = file(incidentID: receipt.incidentID, root: root) else { return }
        try? FileManager.default.createDirectory(
            at: directory(root: root), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(receipt) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public static func markConfirmed(eventID: String, root: URL, now: Date = Date()) {
        let needle = eventID.filter(\.isHexDigit).lowercased()
        for receipt in loadAll(root: root) where receipt.state == .queued {
            let stored = receipt.eventID.filter(\.isHexDigit).lowercased()
            if stored == needle {
                var updated = receipt
                updated.state = .confirmed
                updated.updatedAt = now
                store(updated, root: root)
                return
            }
        }
    }

    public static func applyTTL(root: URL, now: Date = Date(), ttl: TimeInterval = 604_800) {
        let dir = directory(root: root)
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files where url.pathExtension == "json" {
            let modified =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? now
            if now.timeIntervalSince(modified) > ttl {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    public static func loadAll(root: URL) -> [ReliabilityReportingReceipt] {
        let dir = directory(root: root)
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> ReliabilityReportingReceipt? in
            guard url.pathExtension == "json",
                let data = try? Data(contentsOf: url)
            else { return nil }
            return try? JSONDecoder().decode(ReliabilityReportingReceipt.self, from: data)
        }
    }

    public static func purge(root: URL) {
        try? FileManager.default.removeItem(at: root)
    }
}
