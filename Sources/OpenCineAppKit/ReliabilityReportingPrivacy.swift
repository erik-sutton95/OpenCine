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
        "testSource", "buildIdentity", "trigger", "recoveredBy", "background", "awaitingIrap",
        "decoderStatus", "decoderCodec", "watchdogHold",
    ]

    public static let contextAllowlist: [String: Set<String>] = [
        "os": ["name", "version", "build"],
        "device": ["family", "model", "arch", "free_memory", "memory_size", "thermal_state"],
        "app": ["app_version", "app_build", "build_type", "app_memory", "in_foreground"],
        "feed": [
            "schemaVersion", "failingStage", "errorClass", "outcome", "kind",
            "assistState", "hardwareClass", "testSource", "buildIdentity", "cameraFamily",
            "trigger", "recoveredBy", "worstGapSeconds",
            "decoderCall", "keyframeWait", "irapAge", "decodeFlow",
        ],
    ]

    /// The metrics reporting records (`ReliabilityReporting.sessionMetrics`).
    public static let metricAllowlist: Set<String> = [
        "feed.session.healthy_exposure", "feed.session.incidents",
    ]

    /// The attributes those metrics may carry.
    public static let metricAttributeAllowlist: Set<String> = [
        "outcome", "testSource", "buildIdentity", "sourceRevision", "appBuild",
    ]

    /// Keys whose value must come from a closed vocabulary; anything else reads `other`. The
    /// host redaction keeps bare SSIDs and camera names (`ZR_6002199`), so free text that could
    /// carry them is closed instead. Kotlin twin: `closedValues`.
    public static let closedValues: [String: Set<String>] = [
        "trigger": FeedIncidentNativeBreadcrumb.allowedValues["repairReason", default: []]
            .union(["none", "other"]),
        "recoveredBy": FeedIncidentNativeBreadcrumb.allowedValues["repairAction", default: []]
            .union(["none", "other"]),
        // The decode state an incident opened on (FeedIncidentExport); buckets, never counts.
        "decoderCall": FeedIncidentExport.decoderCalls.union(["none", "other"]),
        "keyframeWait": ["awaiting", "none", "unknown", "other"],
        "irapAge": ["never", "0-1s", "1-5s", "5-30s", "30s+", "unknown", "other"],
        "decodeFlow": ["idle", "rejecting", "partial", "flowing", "unknown", "other"],
        // Incident diagnostics (FeedIncidentVendorEnvelope.background / awaitingIrap).
        "background": ["yes", "no", "unknown", "other"],
        "awaitingIrap": ["yes", "no", "unknown", "other"],
        // MonitorUpscaler raw values (Kotlin MonitorGlesUpscaler labels).
        "feedUpscaler": ["Off", "Fast", "Quality", "AI", "other"],
        "decoderCodec": FeedIncidentExport.decoderCodecs.union(["other"]),
        // FeedWatchdog.Hold raw values plus the shell's own pre-tick holds.
        "watchdogHold": FeedIncidentWatchdogGate.holdValues.union(["none", "other"]),
        // Incident outcomes and the session summary's own.
        "outcome": [
            "open", "recovered", "interrupted", "exhausted", "suppressed", "userEnded", "live",
            "ended", "healthy", "no-exposure", "other",
        ],
    ]

    /// Build-pipeline values with a fixed shape (`stamp-source-revision.sh`, `build-identity.py`,
    /// the build number); anything else reads `unknown`. Kotlin twin: `shapes`.
    public static let shapes: [String: String] = [
        "sourceRevision": #"^([0-9a-f]{7,40}(\+|-dirty)?|unknown)$"#,
        "buildIdentity": #"^((ios|android|watchos|wearos|macos)-[0-9a-z]{8,64}|unknown)$"#,
        "appBuild": #"^[0-9]{1,10}$"#,
        // A decoder OSStatus as decimal digits.
        "decoderStatus": #"^(-?[0-9]{1,10}|none)$"#,
    ]

    /// A string as it may leave the phone under `key`: a closed vocabulary or a fixed shape where
    /// one is registered, otherwise clipped to `limit` and redacted by `redact`.
    public static func value(
        _ key: String, _ raw: String, limit: Int = 96,
        redact: (String) -> String = { PrivacyRedactor.redact($0) }
    ) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let closed = closedValues[key] { return closed.contains(trimmed) ? trimmed : "other" }
        if let shape = shapes[key] {
            return trimmed.range(of: shape, options: .regularExpression) != nil
                ? trimmed : "unknown"
        }
        return redact(String(trimmed.prefix(limit)))
    }

    /// A metric as it may leave the phone, or nil: an allow-listed name, a finite value, a known
    /// unit, and only allow-listed attributes with their values bounded like tags.
    public func metric(_ metric: ReliabilityMetric) -> ReliabilityMetric? {
        guard Self.metricAllowlist.contains(metric.name), metric.value.isFinite,
            metric.unit == nil || metric.unit == "second"
        else { return nil }
        var kept = metric
        kept.attributes = [:]
        for (key, raw) in metric.attributes where Self.metricAttributeAllowlist.contains(key) {
            kept.attributes[key] = Self.value(key, raw, limit: 32, redact: redact)
        }
        return kept
    }

    public static let tagAllowlist: Set<String> = [
        "failingStage", "errorClass", "outcome", "kind",
        "sourceRevision", "cameraFamily", "cameraFirmware", "hardwareClass",
        "testSource", "buildIdentity", "trigger", "recoveredBy", "gap", "feedUpscaler",
        "decoderCall", "keyframeWait", "irapAge", "decodeFlow",
        "background", "awaitingIrap",
        "decoderStatus", "decoderCodec", "watchdogHold",
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
        // The attachment carries the build values bounded as tags are (repairs close at init).
        var bundle = bundle
        bundle.repairs = bundle.repairs.map { $0.closed() }
        bundle.header.sourceRevision = value("sourceRevision", bundle.header.sourceRevision)
        bundle.header.buildIdentity = bundle.header.buildIdentity.map { value("buildIdentity", $0) }
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

    /// An exception value as it may leave the phone: the SDK's own lifecycle messages (hang
    /// duration, watchdog kill, ANR) carry no app data and say what happened, so they stay;
    /// anything else may hold user or app text and is replaced. Kotlin twin: `exceptionValue`.
    public static func exceptionValue(_ raw: String) -> String {
        sdkLifecycleMessages.contains { raw.range(of: $0, options: .regularExpression) != nil }
            ? raw : "Native exception"
    }

    private static let sdkLifecycleMessages = [
        #"^App hanging (for at least [0-9]+ ms|between [0-9.]+ and [0-9.]+ seconds)\.$"#,
        #"^The user or the OS watchdog terminated your app while it blocked the main thread for "#
            + #"(at least [0-9]+ ms|between [0-9.]+ and [0-9.]+ seconds|\?)\.$"#,
        #"^The OS watchdog terminated your app, possibly because it overused RAM\.$"#,
        #"^(Background )?(ANR|Application Not Responding for at least [0-9]+ ms\.)$"#,
    ]

    /// Allowlisted tags, each clipped and redacted; nil when none is left.
    public func tags(_ tags: [String: String]) -> [String: String]? {
        var kept = tags.filter { Self.tagAllowlist.contains($0.key) }
        for key in kept.keys {
            kept[key] = Self.value(key, kept[key] ?? "", limit: 32, redact: redact)
        }
        return kept.isEmpty ? nil : kept
    }

    /// Allowlisted extras, string values bounded like tags (`value`); nil when none is left.
    public static func extra(_ extra: [String: Any]) -> [String: Any]? {
        var kept = extra.filter { extraAllowlist.contains($0.key) }
        for (key, raw) in kept { if let text = raw as? String { kept[key] = value(key, text) } }
        return kept.isEmpty ? nil : kept
    }

    /// Allowlisted context sections and keys, string values bounded like tags; nil when none is
    /// left.
    public static func context(_ context: [String: [String: Any]]) -> [String: [String: Any]]? {
        var kept: [String: [String: Any]] = [:]
        for (section, values) in context {
            guard let allow = contextAllowlist[section] else { continue }
            var filtered = values.filter { allow.contains($0.key) }
            for (key, raw) in filtered {
                if let text = raw as? String { filtered[key] = value(key, text) }
            }
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
