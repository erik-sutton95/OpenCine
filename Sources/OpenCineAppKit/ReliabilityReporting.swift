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
    /// A `ReliabilityEnvironment` raw value.
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
        ReliabilityEnvironment(rawValue: environment)?.tracksWatchdogTerminations ?? false
    }
}

/// Where a build came from, as every report names it. Only store builds are `production`.
/// Kotlin twin: `reportingEnvironment` in the build-logic reporting plugin.
public enum ReliabilityEnvironment: String, Sendable, CaseIterable {
    /// A debug build.
    case development
    /// A debug build under the verification harness.
    case verification
    /// A release build installed outside a store: Xcode, ad hoc, a simulator, a local Gradle run.
    case local
    /// An iOS TestFlight build.
    case testflight
    /// An Android build from the Play testing pipeline.
    case `internal`
    /// A store build.
    case production

    /// Builds that are reinstalled at will, where a reinstall reads as a watchdog kill.
    public var tracksWatchdogTerminations: Bool {
        switch self {
        case .development, .verification, .local: false
        case .testflight, .internal, .production: true
        }
    }

    /// An Apple build: a release build that carries a provisioning profile (Xcode, ad hoc) or runs
    /// on a simulator is local; App Store and TestFlight builds carry none and tell themselves
    /// apart by their receipt.
    public static func apple(
        debug: Bool, verification: Bool, simulator: Bool, embeddedProfile: Bool,
        receiptName: String?
    ) -> Self {
        if debug { return verification ? .verification : .development }
        if simulator || embeddedProfile { return .local }
        return receiptName == "sandboxReceipt" ? .testflight : .production
    }

    /// `apple(...)` for this process and `bundle`. `debug` and `verification` are the app's own
    /// compile-time facts.
    public static func apple(debug: Bool, verification: Bool, bundle: Bundle = .main) -> Self {
        #if targetEnvironment(simulator)
            let simulator = true
        #else
            let simulator = false
        #endif
        return apple(
            debug: debug, verification: verification, simulator: simulator,
            embeddedProfile: bundle.path(forResource: "embedded", ofType: "mobileprovision") != nil,
            receiptName: bundle.appStoreReceiptURL?.lastPathComponent)
    }
}

/// The operator's automatic-report choice. Absent is undecided; a stored false is a decline.
public final class ReliabilityReportingConsent: @unchecked Sendable {
    public static let defaultsKey = "opc.reliabilityReporting.optIn"
    public static let installIDKey = "opc.reliabilityReporting.installID"
    /// Swapped only by isolated review and verification launches and by tests.
    public var defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasDecision: Bool { defaults.object(forKey: Self.defaultsKey) != nil }

    public var isOptedIn: Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    /// The anonymous install id reports count users by: a random UUID made on first use while
    /// the operator has opted in, never derived from the device or personal data. nil without
    /// consent; withdrawing consent deletes it, so a later opt-in starts a new one.
    public var installID: String? {
        lock.lock()
        defer { lock.unlock() }
        guard isOptedIn else { return nil }
        // Only a value this store made is sent: anything else in the slot is replaced.
        if let stored = defaults.string(forKey: Self.installIDKey),
            UUID(uuidString: stored)?.uuidString.lowercased() == stored
        {
            return stored
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: Self.installIDKey)
        return created
    }

    public func setOptedIn(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(on, forKey: Self.defaultsKey)
        if !on { defaults.removeObject(forKey: Self.installIDKey) }
    }

    public func resetForTests() {
        defaults.removeObject(forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.installIDKey)
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

/// One measurement for the host SDK's metrics, never an issue event. `unit` is a Sentry unit
/// name (`second`) or nil; attributes are low-cardinality strings.
public struct ReliabilityMetric: Equatable, Sendable {
    public var name: String
    public var value: Double
    public var unit: String?
    public var attributes: [String: String]

    public init(
        name: String, value: Double, unit: String? = nil, attributes: [String: String] = [:]
    ) {
        self.name = name
        self.value = value
        self.unit = unit
        self.attributes = attributes
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
    /// Records one distribution sample. Main thread.
    func record(_ metric: ReliabilityMetric)
}

extension ReliabilityReportingSink {
    /// Metrics are optional for existing host sinks. Supporting sinks override this method.
    public func record(_ metric: ReliabilityMetric) {}
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
    private var metricHandler: ((ReliabilityMetric) -> Void)?
    private var feedUpscaler: String?
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
        sink.addBreadcrumb(
            category: "feed", message: "repair", data: details.isEmpty ? nil : details)
    }

    /// The feed upscaler in effect (`MonitorUpscaler` raw value), a scope tag on every later event
    /// and crash: a super-resolution crash (PI-3M) said nothing about the mode. Main thread.
    public func noteFeedUpscaler(_ upscaler: String) {
        let value = ReliabilityReportingPrivacy.value("feedUpscaler", upscaler)
        feedUpscaler = value
        guard isOptedIn, sdkStarted, sink.isEnabled else { return }
        sink.setTags(["feedUpscaler": value])
    }

    /// The current run's scope tags, set when the SDK starts, bounded by the same rules as event
    /// tags (crash events carry them). Main thread.
    public var scopeTags: [String: String] {
        var tags = [
            "sourceRevision": host.sourceRevision,
            "testSource": origin.currentTestSource().rawValue,
            "buildIdentity": origin.currentBuildIdentity(),
        ]
        if let feedUpscaler { tags["feedUpscaler"] = feedUpscaler }
        return privacy.tags(tags) ?? [:]
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

    public func setMetricHandlerForTests(_ handler: ((ReliabilityMetric) -> Void)?) {
        metricHandler = handler
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
                    sink.setTags(scopeTags)
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
        // Header provenance is assigned after makeEvent, so scrub the completed payload too.
        capturePayload(
            event: privacy.scrub(event), json: json, id: envelope.incidentID, epoch: capturedEpoch)
    }

    /// The feed's denominator as metrics, never an issue event (it was the largest issue by
    /// volume, PA-2/II-1/PI-W): healthy exposure seconds and incident count per ended session.
    /// Recorded once per session; a confirmed receipt outlives the summary on disk.
    private func captureSessionSummary(
        _ summary: FeedIncidentSessionSummary, epoch capturedEpoch: UInt64
    ) {
        guard summary.outcome != "live", UUID(uuidString: summary.sessionID) != nil,
            summary.healthyExposureSeconds.isFinite, summary.healthyExposureSeconds >= 0,
            capturedEpoch == currentEpoch(), consent.isOptedIn, !gate.shouldBlockUpload
        else { return }
        let id = "session-" + summary.sessionID
        ReliabilityReportingReceipts.applyTTL(root: sdkCacheRoot)
        guard ReliabilityReportingReceipts.load(incidentID: id, root: sdkCacheRoot) == nil,
            pendingCaptureIDs.insert(id).inserted
        else { return }
        let metrics = Self.sessionMetrics(summary).compactMap(privacy.metric)
        DispatchQueue.main.async { [self] in
            defer { queue.async { [self] in pendingCaptureIDs.remove(id) } }
            guard capturedEpoch == currentEpoch(), consent.isOptedIn,
                sdkStarted || metricHandler != nil
            else { return }
            for metric in metrics {
                if let metricHandler { metricHandler(metric) } else { sink.record(metric) }
            }
            queue.async { [self] in
                guard capturedEpoch == currentEpoch(), consent.isOptedIn else { return }
                ReliabilityReportingReceipts.store(
                    ReliabilityReportingReceipt(
                        incidentID: id, eventID: "", state: .confirmed, updatedAt: Date()),
                    root: sdkCacheRoot)
            }
        }
    }

    public static func sessionMetrics(_ summary: FeedIncidentSessionSummary) -> [ReliabilityMetric]
    {
        var attributes = [
            "outcome": summary.outcome,
            "testSource": (summary.testSource ?? .unknown).rawValue,
            "buildIdentity": FeedIncidentBuildIdentity.parse(summary.buildIdentity),
            "sourceRevision": summary.sourceRevision,
        ]
        if let build = summary.appBuild { attributes["appBuild"] = build }
        return [
            ReliabilityMetric(
                name: "feed.session.healthy_exposure", value: summary.healthyExposureSeconds,
                unit: "second", attributes: attributes),
            ReliabilityMetric(
                name: "feed.session.incidents", value: Double(summary.incidentCount),
                attributes: attributes),
        ]
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

    private func makeEvent(envelope: FeedIncidentVendorEnvelope, eventID: String)
        -> ReliabilityEvent
    {
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
            "decoderCall": envelope.decoderCall,
            "keyframeWait": envelope.keyframeWait,
            "irapAge": envelope.irapAge,
            "decodeFlow": envelope.decodeFlow,
            // Diagnostics: no bundle attachment reaches the issue, so these two say whether
            // the gap spanned an app switch and whether a keyframe was pending.
            "background": envelope.background,
            "awaitingIrap": envelope.awaitingIrap,
            "decoderStatus": envelope.decoderStatus,
            "decoderCodec": envelope.decoderCodec,
            "watchdogHold": envelope.watchdogHold,
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
            "background": envelope.background,
            "awaitingIrap": envelope.awaitingIrap,
            "decoderStatus": envelope.decoderStatus,
            "decoderCodec": envelope.decoderCodec,
            "watchdogHold": envelope.watchdogHold,
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
                "decoderCall": envelope.decoderCall,
                "keyframeWait": envelope.keyframeWait,
                "irapAge": envelope.irapAge,
                "decodeFlow": envelope.decodeFlow,
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
