import Foundation
import Network
import OpenCineMedia

// An app's opt-in crash and incident reporting, without the reporting SDK: the host values,
// consent, destination, typed events and their delivery bookkeeping. The app builds one of each
// in its diagnostics holder and implements `ReliabilityReportingSink` over its SDK. Kotlin mirror:
// `appkit/diagnostics/ReliabilityReporting.kt` and `DiagnosticsHost.kt`.

/// The host app's identity and policy for diagnostics. Every name and destination belongs to the
/// app; this module owns none.
public struct DiagnosticsHost: Sendable {
    /// App name in copy the operator reads.
    public var product: String
    /// Name that heads diagnostic listings (the incident export).
    public var listingName: String
    /// Events carry the release `<releasePackage>@<version>+<build>`.
    public var releasePackage: String
    public var version: String
    public var build: String
    /// development, verification, testflight or production.
    public var environment: String
    public var sourceRevision: String
    public var supportEmail: String
    /// The host's redaction policy for everything that leaves the phone.
    public var redact: @Sendable (String) -> String

    public init(
        product: String, listingName: String, releasePackage: String, version: String,
        build: String, environment: String, sourceRevision: String, supportEmail: String,
        redact: @escaping @Sendable (String) -> String
    ) {
        self.product = product
        self.listingName = listingName
        self.releasePackage = releasePackage
        self.version = version
        self.build = build
        self.environment = environment
        self.sourceRevision = sourceRevision
        self.supportEmail = supportEmail
        self.redact = redact
    }

    public func release(version: String? = nil, build: String? = nil) -> String {
        "\(releasePackage)@\(version ?? self.version)+\(build ?? self.build)"
    }

    /// Reinstalling a development build looks like a watchdog kill to the SDK (81 of
    /// 86 WatchdogTermination events came from developer installs). TestFlight and
    /// App Store keep it.
    public var tracksWatchdogTerminations: Bool {
        !["development", "verification"].contains(environment)
    }
}

/// The operator's automatic-report choice. Absent is undecided; a stored false is a decline.
public final class ReliabilityReportingConsent: @unchecked Sendable {
    public static let defaultsKey = "opc.reliabilityReporting.optIn"
    /// Swapped only by isolated review and verification launches and by tests.
    public var defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasDecision: Bool { defaults.object(forKey: Self.defaultsKey) != nil }

    public var isOptedIn: Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    public func setOptedIn(_ on: Bool) {
        defaults.set(on, forKey: Self.defaultsKey)
    }

    public func resetForTests() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

/// The automatic-report destination: the first valid of the host's candidates, read on every call.
public struct ReliabilityReportingDSN: Sendable {
    private let candidates: @Sendable () -> [String?]

    public init(candidates: @escaping @Sendable () -> [String?]) {
        self.candidates = candidates
    }

    public func configured() -> String? {
        for raw in candidates() {
            if let value = Self.validated(raw) { return value }
        }
        return nil
    }

    public var isAvailable: Bool { configured() != nil }

    public static func validated(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("YOUR_"), !trimmed.contains("example") else {
            return nil
        }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
            return nil
        }
        guard let host = url.host, !host.isEmpty else { return nil }
        guard let user = url.user, !user.isEmpty else { return nil }
        guard url.password == nil, url.query == nil, url.fragment == nil,
            let project = url.path.split(separator: "/").last,
            !project.isEmpty, project.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return trimmed
    }
}

public enum ReliabilityEventLevel: Sendable {
    case info, warning, error
}

/// One typed event for the host's reporting SDK, which sends it with the attachment it is
/// captured with. `extra` and `context` hold strings and numbers only.
public struct ReliabilityEvent: @unchecked Sendable {
    /// 32 lowercase hex digits, as the SDK prints its event id.
    public var eventID: String
    public var level: ReliabilityEventLevel
    public var timestamp: Date? = Date()
    public var release: String?
    public var dist: String?
    public var message: String
    public var fingerprint: [String] = []
    public var tags: [String: String]?
    public var extra: [String: Any]?
    public var context: [String: [String: Any]]?
    /// Whether the SDK may attach its recent breadcrumbs. A scrubbed event carries only its own.
    public var attachesRecentBreadcrumbs = true

    public init(eventID: String, level: ReliabilityEventLevel, message: String) {
        self.eventID = eventID
        self.level = level
        self.message = message
    }
}

/// The calls reporting makes into the host's SDK. The host applies `ReliabilityReporting.privacy`
/// to every event and breadcrumb it sends (crashes included) and uploads only through the gate.
public protocol ReliabilityReportingSink: AnyObject, Sendable {
    var isEnabled: Bool { get }
    /// Starts the SDK for `dsn`, caching under `cacheRoot`. Main thread.
    func start(dsn: String, cacheRoot: URL)
    /// Stops the SDK; its cache is purged afterwards. Main thread.
    func close()
    func flush(timeout: TimeInterval)
    func addBreadcrumb(category: String, message: String, data: [String: String]?)
    /// Sets these tags on the SDK scope in one update. Main thread.
    func setTags(_ tags: [String: String])
    /// Captures `event` with `attachment` (JSON) named `attachmentName` as its only attachment,
    /// keeping the event's own tags over the scope's. Main thread.
    func capture(_ event: ReliabilityEvent, attachment: Data, attachmentName: String)
}

/// Opt-in automatic reporting, installed by the app and gated by the camera path.
/// Does not start without persisted consent and a valid https DSN. Does not mark
/// an incident delivered when it is only queued.
public final class ReliabilityReporting: @unchecked Sendable {
    public let host: DiagnosticsHost
    public let consent: ReliabilityReportingConsent
    public let dsn: ReliabilityReportingDSN
    public let gate: ReliabilityReportingGate
    public let origin: FeedIncidentOrigin
    public let privacy: ReliabilityReportingPrivacy
    private let sink: ReliabilityReportingSink
    private let queue = DispatchQueue(label: "opv.reliability", qos: .utility)
    private let stateLock = NSLock()
    private var startedStorage = false
    private var sdkStarted: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return startedStorage
        }
        set {
            stateLock.lock()
            startedStorage = newValue
            stateLock.unlock()
        }
    }
    private var pathMonitor: NWPathMonitor?
    private var resumeScheduled = false
    private var idlePollScheduled = false
    private var resumeAttempt = 0
    private var epoch: UInt64 = 0
    private var captureHandler: ((ReliabilityEvent, Data) -> Void)?
    private var pendingCaptureIDs: Set<String> = []
    private var pendingEventIDs: [String: String] = [:]
    private var finalizedSpoolLoader: @Sendable () -> [FeedIncidentBundle] = { [] }
    private var sessionSummaryLoader: @Sendable () -> [FeedIncidentSessionSummary] = { [] }
    /// The DSN's host, the only one the SDK's transport may reach.
    public var dsnHost: String?
    public var sdkCacheRoot: URL = {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("opc-reliability-sdk", isDirectory: true)
    }()

    public init(
        host: DiagnosticsHost, consent: ReliabilityReportingConsent, dsn: ReliabilityReportingDSN,
        gate: ReliabilityReportingGate, origin: FeedIncidentOrigin, sink: ReliabilityReportingSink
    ) {
        self.host = host
        self.consent = consent
        self.dsn = dsn
        self.gate = gate
        self.origin = origin
        self.privacy = ReliabilityReportingPrivacy(redact: host.redact)
        self.sink = sink
    }

    public var isOptedIn: Bool { consent.isOptedIn }
    public var isAvailable: Bool { dsn.isAvailable }

    public func noteBreadcrumb(_ source: FeedIncidentBreadcrumb) {
        guard isOptedIn, sink.isEnabled else { return }
        let details = FeedIncidentNativeBreadcrumb.details(kind: source.kind, detail: source.detail)
        sink.addBreadcrumb(
            category: "feed", message: source.kind.rawValue, data: details.isEmpty ? nil : details)
    }

    public func noteRepair(_ repair: FeedRepairRecord) {
        guard isOptedIn, sink.isEnabled else { return }
        let details = FeedIncidentNativeBreadcrumb.details(repair: repair)
        sink.addBreadcrumb(category: "feed", message: "repair", data: details.isEmpty ? nil : details)
    }

    /// Once-only current-run scope upgrade. Does not rewrite queued/fatal tags.
    public func noteCurrentTestSource(_ source: FeedIncidentTestSource) {
        guard isOptedIn else { return }
        DispatchQueue.main.async { [self] in
            guard sink.isEnabled else { return }
            sink.setTags(["testSource": source.rawValue])
        }
    }

    public func install() {
        if let dsn = dsn.configured() {
            dsnHost = ReliabilityReportingHostPolicy.host(fromDSN: dsn)
        }
        applySDKState()
    }

    /// Holds reports back from this connect attempt (recovery included) until the returned lease
    /// ends, when its owner retires. Each owner keeps its own lease; uploads resume after the last
    /// one ends. Main thread.
    public func beginCameraPath() -> ReliabilityCameraPathLease {
        gate.beginCameraPath { [weak self] in
            if Thread.isMainThread {
                self?.cameraPathCleared()
            } else {
                DispatchQueue.main.async { self?.cameraPathCleared() }
            }
        }
    }

    private func cameraPathCleared() {
        if !sdkStarted, consent.isOptedIn {
            applySDKState()
        }
        enqueueFinalizedFromSpool()
        scheduleResumeIfIdle()
    }

    public func setConsent(_ on: Bool) {
        bumpEpoch()
        consent.setOptedIn(on)
        if !on {
            gate.cancelPending(includeIndependent: false)
        }
        applySDKState()
    }

    public func setFinalizedSpoolLoader(_ loader: @escaping @Sendable () -> [FeedIncidentBundle]) {
        queue.async { [self] in finalizedSpoolLoader = loader }
    }

    public func setSessionSummaryLoader(
        _ loader: @escaping @Sendable () -> [FeedIncidentSessionSummary]
    ) {
        queue.async { [self] in sessionSummaryLoader = loader }
    }

    public static func isFinalized(_ bundle: FeedIncidentBundle) -> Bool {
        switch bundle.header.outcome {
        case .open: return false
        case .recovered, .interrupted, .exhausted, .suppressed, .userEnded: return true
        }
    }

    /// Enqueue a finalized incident once. Open/checkpoint/repair snapshots stay local.
    public func enqueueFinalized(_ bundle: FeedIncidentBundle) {
        let capturedEpoch = currentEpoch()
        queue.async { [self] in captureIfFinalized(bundle, epoch: capturedEpoch) }
    }

    public func enqueueFinalizedFromSpool() {
        let capturedEpoch = currentEpoch()
        queue.async { [self] in
            guard consent.isOptedIn, capturedEpoch == currentEpoch(), !gate.shouldBlockUpload
            else {
                return
            }
            for bundle in finalizedSpoolLoader() where Self.isFinalized(bundle) {
                captureIfFinalized(bundle, epoch: capturedEpoch)
            }
            for summary in sessionSummaryLoader() {
                captureSessionSummary(summary, epoch: capturedEpoch)
            }
        }
    }

    /// A separate, bounded event includes sessions with no dropout.
    public func noteSessionSummary(_ summary: FeedIncidentSessionSummary) {
        let capturedEpoch = currentEpoch()
        queue.async { [self] in
            captureSessionSummary(summary, epoch: capturedEpoch)
        }
    }

    public func receipt(for incidentID: String) -> ReliabilityReportingReceipt? {
        ReliabilityReportingReceipts.load(incidentID: incidentID, root: sdkCacheRoot)
    }

    public func setCaptureHandlerForTests(_ handler: ((ReliabilityEvent, Data) -> Void)?) {
        captureHandler = handler
    }

    private func applySDKState() {
        if consent.isOptedIn, let dsn = dsn.configured() {
            scheduleIdlePoll()
            observeInternetIfNeeded()
            // Install local crash/hang capture even when launching on camera Wi-Fi.
            // The dedicated transport independently blocks every upload.
            startSDK(dsn: dsn)
        } else {
            stopAndPurgeSDKOwned()
        }
    }

    private func observeInternetIfNeeded() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [self] path in
            DispatchQueue.main.async { [self] in
                guard consent.isOptedIn else { return }
                if gate.shouldBlockUpload {
                    gate.cancelPending()
                } else if path.status == .satisfied {
                    if !sdkStarted, let dsn = dsn.configured() {
                        startSDK(dsn: dsn)
                    }
                    enqueueFinalizedFromSpool()
                    scheduleResumeIfIdle()
                }
            }
        }
        monitor.start(queue: queue)
    }

    private func startSDK(dsn: String) {
        guard !sdkStarted else {
            enqueueFinalizedFromSpool()
            return
        }
        let capturedEpoch = currentEpoch()
        dsnHost = ReliabilityReportingHostPolicy.host(fromDSN: dsn)
        queue.async { [self] in
            guard capturedEpoch == currentEpoch(), consent.isOptedIn else { return }
            try? FileManager.default.createDirectory(
                at: sdkCacheRoot, withIntermediateDirectories: true)
            DispatchQueue.main.async { [self] in
                guard capturedEpoch == currentEpoch(), consent.isOptedIn else { return }
                if !sdkStarted {
                    sink.start(dsn: dsn, cacheRoot: sdkCacheRoot)
                    sink.setTags([
                        "sourceRevision": host.sourceRevision,
                        "testSource": origin.currentTestSource().rawValue,
                        "buildIdentity": origin.currentBuildIdentity(),
                    ])
                    sdkStarted = true
                }
                enqueueFinalizedFromSpool()
                scheduleResumeIfIdle()
            }
        }
    }

    private func stopAndPurgeSDKOwned() {
        pathMonitor?.cancel()
        pathMonitor = nil
        gate.cancelPending(includeIndependent: false)
        let close: @Sendable () -> Void = { [self] in
            if sdkStarted {
                sink.close()
                sdkStarted = false
            }
            // Ordered before a subsequent start's cache preparation, including
            // a rapid off/on toggle. Prior capture writes are epoch-invalidated.
            queue.async { [self] in
                ReliabilityReportingReceipts.purge(root: sdkCacheRoot)
                try? FileManager.default.removeItem(at: sdkCacheRoot)
            }
        }
        if Thread.isMainThread { close() } else { DispatchQueue.main.async(execute: close) }
    }

    private func captureIfFinalized(_ bundle: FeedIncidentBundle, epoch capturedEpoch: UInt64) {
        guard capturedEpoch == currentEpoch(), consent.isOptedIn else { return }
        guard Self.isFinalized(bundle) else { return }
        guard let envelope = ReliabilityReportingPrivacy.validatedEnvelope(from: bundle) else {
            return
        }
        guard let json = ReliabilityReportingPrivacy.typedJSON(from: bundle) else { return }
        var event = makeEvent(
            envelope: envelope,
            eventID: ReliabilityReportingPrivacy.eventID(fromIncidentID: envelope.incidentID))
        event.timestamp = bundle.header.startedAtWallClock
        event.release = host.release(
            version: bundle.header.appVersion, build: bundle.header.appBuild)
        event.dist = bundle.header.appBuild
        event.tags?["sourceRevision"] = bundle.header.sourceRevision
        event.tags?["cameraFamily"] = bundle.header.cameraFamily
        event.tags?["cameraFirmware"] = bundle.header.cameraFirmware ?? "unknown"
        event.tags?["hardwareClass"] = bundle.header.hardwareClass
        event.tags?["testSource"] = bundle.header.resolvedTestSource.rawValue
        event.tags?["buildIdentity"] = bundle.header.resolvedBuildIdentity
        capturePayload(event: event, json: json, id: envelope.incidentID, epoch: capturedEpoch)
    }

    private func captureSessionSummary(_ summary: FeedIncidentSessionSummary, epoch: UInt64) {
        guard summary.outcome != "live", UUID(uuidString: summary.sessionID) != nil,
            summary.healthyExposureSeconds.isFinite, summary.healthyExposureSeconds >= 0,
            let json = try? FeedIncidentCoding.encoder().encode(summary), json.count <= 4_096
        else { return }
        var event = ReliabilityEvent(
            eventID: ReliabilityReportingPrivacy.eventID(fromIncidentID: summary.sessionID),
            level: .info, message: "Feed session summary")
        event.timestamp = summary.recordedAt
        if let version = summary.appVersion, let build = summary.appBuild {
            event.release = host.release(version: version, build: build)
            event.dist = build
        } else {
            event.release = "legacy-session-unknown-release"
        }
        event.fingerprint = ["feed-session", "schema:1"]
        event.tags = [
            "kind": "sessionSummary", "outcome": summary.outcome,
            "sourceRevision": summary.sourceRevision,
            "testSource": (summary.testSource ?? .unknown).rawValue,
            "buildIdentity": FeedIncidentBuildIdentity.parse(summary.buildIdentity),
        ]
        event.extra = [
            "healthyExposureSeconds": summary.healthyExposureSeconds,
            "incidentCount": summary.incidentCount, "sourceRevision": summary.sourceRevision,
            "testSource": (summary.testSource ?? .unknown).rawValue,
            "buildIdentity": FeedIncidentBuildIdentity.parse(summary.buildIdentity),
        ]
        capturePayload(event: event, json: json, id: "session-" + summary.sessionID, epoch: epoch)
    }

    /// Disk runs on the reporting queue; SDK state/capture is checked on main.
    /// A queued receipt can be retried after five minutes if SDK cache eviction
    /// or an interrupted handoff lost it. Stable event IDs deduplicate delivery.
    private func capturePayload(
        event: ReliabilityEvent, json: Data, id: String, epoch capturedEpoch: UInt64
    ) {
        guard capturedEpoch == currentEpoch(), consent.isOptedIn, !gate.shouldBlockUpload
        else { return }
        ReliabilityReportingReceipts.applyTTL(root: sdkCacheRoot)
        if let receipt = ReliabilityReportingReceipts.load(incidentID: id, root: sdkCacheRoot),
            receipt.state == .confirmed || Date().timeIntervalSince(receipt.updatedAt) < 300
        {
            return
        }
        guard pendingCaptureIDs.insert(id).inserted else { return }
        pendingEventIDs[id] = event.eventID
        DispatchQueue.main.async { [self] in
            guard capturedEpoch == currentEpoch(), consent.isOptedIn,
                sdkStarted || captureHandler != nil
            else {
                queue.async { [self] in
                    pendingCaptureIDs.remove(id)
                    pendingEventIDs.removeValue(forKey: id)
                }
                return
            }
            defer {
                queue.async { [self] in
                    pendingCaptureIDs.remove(id)
                    pendingEventIDs.removeValue(forKey: id)
                }
            }
            if let captureHandler {
                captureHandler(event, json)
            } else {
                sink.capture(event, attachment: json, attachmentName: id + ".json")
            }
            queue.async { [self] in
                guard capturedEpoch == currentEpoch(), consent.isOptedIn else { return }
                // A fast transport can confirm before this queued write runs.
                guard
                    ReliabilityReportingReceipts.load(incidentID: id, root: sdkCacheRoot)?.state
                        != .confirmed
                else {
                    return
                }
                ReliabilityReportingReceipts.store(
                    ReliabilityReportingReceipt(
                        incidentID: id, eventID: event.eventID, state: .queued, updatedAt: Date()),
                    root: sdkCacheRoot)
            }
        }
    }

    private func bumpEpoch() {
        stateLock.lock()
        epoch += 1
        stateLock.unlock()
    }

    private func currentEpoch() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return epoch
    }

    public func noteTransportSuccess(eventID: String) {
        let capturedEpoch = currentEpoch()
        queue.async { [self] in
            guard capturedEpoch == currentEpoch(), consent.isOptedIn else { return }
            for (id, pendingEventID) in pendingEventIDs where pendingEventID == eventID {
                ReliabilityReportingReceipts.store(
                    ReliabilityReportingReceipt(
                        incidentID: id, eventID: eventID, state: .confirmed, updatedAt: Date()),
                    root: sdkCacheRoot)
            }
            ReliabilityReportingReceipts.markConfirmed(eventID: eventID, root: sdkCacheRoot)
        }
    }

    /// Only an incident the recovery ladder gave up on is an error. Recovered and
    /// suppressed ones are the reliability baseline, not failures.
    public static func level(forOutcome outcome: String) -> ReliabilityEventLevel {
        switch outcome {
        case FeedIncidentOutcome.exhausted.rawValue: return .error
        case FeedIncidentOutcome.interrupted.rawValue, FeedIncidentOutcome.userEnded.rawValue:
            return .warning
        default: return .info
        }
    }

    private func makeEvent(envelope: FeedIncidentVendorEnvelope, eventID: String) -> ReliabilityEvent {
        // Kind is in the fingerprint, so the issue title stays stable per group.
        var event = ReliabilityEvent(
            eventID: eventID, level: Self.level(forOutcome: envelope.grouping.outcome),
            message: "feed incident \(envelope.grouping.failingStage): \(envelope.kind)")
        event.fingerprint = privacy.fingerprint(
            schema: envelope.schemaVersion,
            kind: envelope.kind,
            stage: envelope.grouping.failingStage,
            errorClass: envelope.grouping.errorClass)
        event.tags = [
            "failingStage": envelope.grouping.failingStage,
            "errorClass": envelope.grouping.errorClass,
            "outcome": envelope.grouping.outcome,
            "kind": envelope.kind,
            "testSource": envelope.testSource,
            "buildIdentity": envelope.buildIdentity,
            "trigger": envelope.trigger,
            "recoveredBy": envelope.recoveredBy,
            "gap": FeedIncidentExport.gapBucket(envelope.worstGapSeconds),
        ]
        event.extra = [
            "schemaVersion": envelope.schemaVersion,
            "failingStage": envelope.grouping.failingStage,
            "errorClass": envelope.grouping.errorClass,
            "outcome": envelope.grouping.outcome,
            "kind": envelope.kind,
            "hardwareClass": envelope.grouping.hardwareClass,
            "cameraFirmware": envelope.grouping.cameraFirmware,
            "assistState": envelope.grouping.assistState,
            "decoderGeneration": envelope.decoderGeneration,
            "socketGeneration": envelope.socketGeneration,
            "worstGapSeconds": envelope.worstGapSeconds,
            "healthyExposureSeconds": envelope.healthyExposureSeconds,
            "testSource": envelope.testSource,
            "buildIdentity": envelope.buildIdentity,
            "trigger": envelope.trigger,
            "recoveredBy": envelope.recoveredBy,
        ]
        event.context = [
            "feed": [
                "schemaVersion": envelope.schemaVersion,
                "failingStage": envelope.grouping.failingStage,
                "errorClass": envelope.grouping.errorClass,
                "outcome": envelope.grouping.outcome,
                "kind": envelope.kind,
                "assistState": envelope.grouping.assistState,
                "hardwareClass": envelope.grouping.hardwareClass,
                "testSource": envelope.testSource,
                "buildIdentity": envelope.buildIdentity,
                "trigger": envelope.trigger,
                "recoveredBy": envelope.recoveredBy,
                "worstGapSeconds": envelope.worstGapSeconds,
            ]
        ]
        return privacy.scrub(event)
    }

    private func scheduleIdlePoll() {
        guard !idlePollScheduled else { return }
        idlePollScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [self] in
            idlePollScheduled = false
            guard consent.isOptedIn, let dsn = dsn.configured() else { return }
            if !gate.shouldBlockUpload {
                startSDK(dsn: dsn)
                enqueueFinalizedFromSpool()
                scheduleResumeIfIdle()
            }
            scheduleIdlePoll()
        }
    }

    private func scheduleResumeIfIdle() {
        guard !gate.shouldBlockUpload, consent.isOptedIn, sdkStarted, !resumeScheduled else {
            return
        }
        resumeScheduled = true
        let attempt = resumeAttempt
        resumeAttempt = min(resumeAttempt + 1, 6)
        let jitter = Double((attempt * 37) % 100) / 100
        let delay = ReliabilityReportingBackoff.delaySeconds(attempt: attempt, jitter: jitter)
        let capturedEpoch = currentEpoch()
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            defer { DispatchQueue.main.async { [self] in resumeScheduled = false } }
            guard capturedEpoch == currentEpoch(), consent.isOptedIn, !gate.shouldBlockUpload,
                sdkStarted
            else { return }
            sink.flush(timeout: 2)
            DispatchQueue.main.async { [self] in resumeAttempt = 0 }
        }
    }
}
