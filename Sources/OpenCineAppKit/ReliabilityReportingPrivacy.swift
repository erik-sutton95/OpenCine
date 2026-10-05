import Foundation
import OpenCineMedia

/// What may leave the phone. The host's SDK adapter applies these rules to every event and
/// breadcrumb (crashes included); typed events are built and scrubbed here with the same rules.
/// `redact` is the host's redaction policy. Kotlin mirror: `ReliabilityReportingPrivacy`.
public struct ReliabilityReportingPrivacy: Sendable {
    public let redact: @Sendable (String) -> String

    public init(redact: @escaping @Sendable (String) -> String) {
        self.redact = redact
    }

    public static let extraAllowlist: Set<String> = [
        "schemaVersion", "failingStage", "errorClass", "outcome", "kind",
        "incidentCount", "sourceRevision", "hardwareClass", "cameraFirmware", "assistState",
        "decoderGeneration",
        "socketGeneration", "worstGapSeconds", "healthyExposureSeconds", "incidentCount",
        "testSource", "buildIdentity", "trigger", "recoveredBy",
    ]

    public static let contextAllowlist: [String: Set<String>] = [
        "os": ["name", "version", "build"],
        "device": ["family", "model", "arch", "free_memory", "memory_size", "thermal_state"],
        "app": ["app_version", "app_build", "build_type", "app_memory", "in_foreground"],
        "feed": [
            "schemaVersion", "failingStage", "errorClass", "outcome", "kind",
            "assistState", "hardwareClass", "testSource", "buildIdentity", "cameraFamily",
            "trigger", "recoveredBy", "worstGapSeconds",
        ],
    ]

    public static let tagAllowlist: Set<String> = [
        "failingStage", "errorClass", "outcome", "kind",
        "sourceRevision", "cameraFamily", "cameraFirmware", "hardwareClass",
        "testSource", "buildIdentity", "trigger", "recoveredBy", "gap",
    ]

    /// 32 lowercase hex digits from an incident or session id, as the SDK reads and prints a
    /// UUID string: the first 32 hex digits, zero-padded; all zeros when they are not a UUID.
    public static func eventID(fromIncidentID raw: String) -> String {
        var hex = raw.filter { $0.isHexDigit }
        if hex.count < 32, let uuid = UUID(uuidString: raw) {
            hex = uuid.uuidString.filter { $0.isHexDigit }
        }
        while hex.count < 32 { hex.append("0") }
        let digits = Array(hex.prefix(32))
        let dashed = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
            .map { String(digits[$0]) }.joined(separator: "-")
        guard let uuid = UUID(uuidString: dashed) else { return String(repeating: "0", count: 32) }
        return uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// A string that names a grouping value, clipped and redacted.
    public func token(_ raw: String) -> String {
        let clipped = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        return redact(clipped)
    }

    public func fingerprint(schema: Int, kind: String, stage: String, errorClass: String)
        -> [String]
    {
        [
            "feed-incident",
            "schema:\(schema)",
            "kind:\(token(kind))",
            "stage:\(token(stage))",
            "errorClass:\(token(errorClass))",
        ]
    }

    public static func validatedEnvelope(from bundle: FeedIncidentBundle)
        -> FeedIncidentVendorEnvelope?
    {
        let envelope = FeedIncidentExport.envelope(from: bundle)
        guard envelope.schemaVersion >= 1 else { return nil }
        guard envelope.eventName == "feed.incident" else { return nil }
        let id = envelope.incidentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id != "unknown" else { return nil }
        let stage = envelope.grouping.failingStage
        guard FeedIncidentFailingStage(rawValue: stage) != nil else { return nil }
        return envelope
    }

    public static func typedJSON(from bundle: FeedIncidentBundle) -> Data? {
        guard validatedEnvelope(from: bundle) != nil else { return nil }
        guard let data = try? FeedIncidentCoding.encoder().encode(bundle) else { return nil }
        if data.count > 262_144 { return nil }
        return data
    }

    /// Only typed feed breadcrumbs leave the phone.
    public static func keepsBreadcrumb(category: String?, message: String?) -> Bool {
        guard category == "feed", let message else { return false }
        return FeedIncidentNativeBreadcrumb.isAllowedMessage(message)
    }

    /// The string values a kept breadcrumb may carry; nil when none is left.
    public static func breadcrumbData(_ data: [String: Any]?) -> [String: String]? {
        var strings: [String: String] = [:]
        for (key, value) in data ?? [:] {
            if let text = value as? String { strings[key] = text }
        }
        let kept = FeedIncidentNativeBreadcrumb.sanitized(strings)
        return kept.isEmpty ? nil : kept
    }

    /// Typed feed events keep their message, redacted; anything else says only what it is.
    public func message(_ formatted: String, fingerprint: [String]?) -> String {
        let isTypedFeedEvent =
            fingerprint?.first == "feed-incident" || fingerprint?.first == "feed-session"
        return isTypedFeedEvent ? redact(formatted) : "Application diagnostic"
    }

    /// Allowlisted tags, each clipped and redacted; nil when none is left.
    public func tags(_ tags: [String: String]) -> [String: String]? {
        var kept = tags.filter { Self.tagAllowlist.contains($0.key) }
        for key in kept.keys {
            let limit = (key == "sourceRevision" || key == "buildIdentity") ? 64 : 32
            kept[key] = redact(String((kept[key] ?? "").prefix(limit)))
        }
        return kept.isEmpty ? nil : kept
    }

    /// Allowlisted extras; nil when none is left.
    public static func extra(_ extra: [String: Any]) -> [String: Any]? {
        let kept = extra.filter { extraAllowlist.contains($0.key) }
        return kept.isEmpty ? nil : kept
    }

    /// Allowlisted context sections and keys; nil when none is left.
    public static func context(_ context: [String: [String: Any]]) -> [String: [String: Any]]? {
        var kept: [String: [String: Any]] = [:]
        for (section, values) in context {
            guard let allow = contextAllowlist[section] else { continue }
            let filtered = values.filter { allow.contains($0.key) }
            if !filtered.isEmpty { kept[section] = filtered }
        }
        return kept.isEmpty ? nil : kept
    }

    /// The scrub the SDK adapter applies, for an event built here.
    public func scrub(_ event: ReliabilityEvent) -> ReliabilityEvent {
        var event = event
        event.attachesRecentBreadcrumbs = false
        event.message = message(event.message, fingerprint: event.fingerprint)
        event.tags = event.tags.flatMap(tags)
        event.extra = event.extra.flatMap(Self.extra)
        event.context = event.context.flatMap(Self.context)
        return event
    }
}
