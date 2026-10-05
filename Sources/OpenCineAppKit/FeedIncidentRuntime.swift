import Foundation
import OpenCineMedia

// The app's feed-incident journal: the current run's origin, the on-device spool and the runtime
// that records into it and hands finalized incidents to reporting. Kotlin mirror:
// `appkit/diagnostics/FeedIncidentOrigin.kt`, `FeedIncidentStore.kt`, `FeedIncidentRuntime.kt`.

/// Current-run origin only. Cached incidents keep the values persisted with them.
public final class FeedIncidentOrigin: @unchecked Sendable {
    public var overrideTestSourceForTests: FeedIncidentTestSource?
    public var overrideBuildIdentityForTests: String?
    private let derivesTestSource: Bool
    private let verification: Bool
    private let buildIdentity: String?
    private let injectionActivated: @Sendable () -> Bool

    /// `derivesTestSource`: a development build tells verification, fault injection and
    /// automation apart; any other build is manual. `buildIdentity` is the build's raw identity.
    public init(
        derivesTestSource: Bool, verification: Bool, buildIdentity: String?,
        injectionActivated: @escaping @Sendable () -> Bool
    ) {
        self.derivesTestSource = derivesTestSource
        self.verification = verification
        self.buildIdentity = buildIdentity
        self.injectionActivated = injectionActivated
    }

    public func resetForTests() {
        overrideTestSourceForTests = nil
        overrideBuildIdentityForTests = nil
    }

    public func currentTestSource(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        injectionActivated: Bool? = nil
    ) -> FeedIncidentTestSource {
        if let overrideTestSourceForTests { return overrideTestSourceForTests }
        guard derivesTestSource else { return .manual }
        return FeedIncidentTestSource.derive(
            verification: verification,
            injectionActivated: injectionActivated ?? self.injectionActivated(),
            automation: Self.isAutomationLaunch(environment))
    }

    /// Launch-env markers that exist in the target app. `XCTestCase` lives in the
    /// test runner; UI-test apps are tagged via these variables instead.
    public static func isAutomationLaunch(_ environment: [String: String]) -> Bool {
        if environment["OPV_FEED_STRESS"] == "1" { return true }
        if environment["OPV_PHYSICAL_UI_REVIEW"] == "1" { return true }
        if let screen = environment["OPV_UI_REVIEW_SCREEN"], !screen.isEmpty { return true }
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        return false
    }

    public func currentBuildIdentity() -> String {
        if let overrideBuildIdentityForTests { return overrideBuildIdentityForTests }
        return FeedIncidentBuildIdentity.parse(buildIdentity)
    }
}

/// On-device incident spool. Journal-independent. No upload. `product` heads its listing.
public struct FeedIncidentStore: Sendable {
    public enum StorageError: Error { case bundleTooLarge }
    public var directory: URL
    public var product: String
    public var limits: FeedIncidentLimits

    public init(directory: URL, product: String, limits: FeedIncidentLimits = .production) {
        self.directory = directory
        self.product = product
        self.limits = limits
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    public func persist(_ job: FeedIncidentPersistenceJob, now: Date = Date()) throws {
        var bundle = job.bundle
        bundle = Self.enforceSize(bundle, maxBytes: limits.maxBundleBytes)
        try write(bundle)
        try applyRetention(now: now)
    }

    public func loadAll() -> [FeedIncidentBundle] {
        urls().compactMap { load(from: $0) }
            .sorted { $0.header.startedAtWallClock > $1.header.startedAtWallClock }
    }

    /// Marks leftover open incidents as process-interrupted, not as a crash.
    @discardableResult
    public func markInterrupted(now: Date = Date()) throws -> [String] {
        try applyRetention(now: now)
        var changed: [String] = []
        for url in urls() {
            guard var bundle = load(from: url), bundle.header.outcome == .open else { continue }
            bundle.header.outcome = .interrupted
            try write(bundle)
            changed.append(bundle.header.incidentID)
        }
        return changed
    }

    public func applyRetention(now: Date) throws {
        var entries: [(url: URL, started: Date, bytes: Int)] = []
        for url in urls() {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            let bytes = values?.fileSize ?? 0
            let started = load(from: url)?.header.startedAtWallClock ?? now
            if now.timeIntervalSince(started) > limits.ttl {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            entries.append((url, started, bytes))
        }
        entries.sort { $0.started < $1.started }
        var total = entries.reduce(0) { $0 + $1.bytes }
        while entries.count > limits.maxBundles || total > limits.maxSpoolBytes,
            let oldest = entries.first
        {
            try? FileManager.default.removeItem(at: oldest.url)
            total -= oldest.bytes
            entries.removeFirst()
        }
    }

    public func deleteAll() throws {
        for url in urls() {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func exportExtras() -> [(name: String, body: String)] {
        FeedIncidentExport.extras(from: loadAll(), product: product)
    }

    private func write(_ bundle: FeedIncidentBundle) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(
            FeedIncidentFileNaming.incident(id: bundle.header.incidentID))
        let data = try FeedIncidentCoding.encoder().encode(bundle)
        guard data.count <= limits.maxBundleBytes else { throw StorageError.bundleTooLarge }
        try data.write(to: url, options: .atomic)
    }

    private func load(from url: URL) -> FeedIncidentBundle? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size <= limits.maxBundleBytes, let data = try? Data(contentsOf: url)
        else { return nil }
        return try? FeedIncidentCoding.decoder().decode(FeedIncidentBundle.self, from: data)
    }

    private func urls() -> [URL] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles])) ?? []
        return files.filter {
            $0.lastPathComponent.hasPrefix("incident-") && $0.pathExtension == "json"
        }
    }

    static func enforceSize(_ bundle: FeedIncidentBundle, maxBytes: Int) -> FeedIncidentBundle {
        var current = bundle
        for _ in 0..<6 {
            guard encodedSize(current) > maxBytes else { return current }
            current.header.evictions += 1
            if current.during.count > 8 {
                current.during = FeedIncidentSampling.downsample(current.during, keep: 8)
                continue
            }
            if current.prelude.count > 8 {
                current.prelude = FeedIncidentSampling.downsample(current.prelude, keep: 8)
                continue
            }
            if current.aftermath.count > 4 {
                current.aftermath = FeedIncidentSampling.downsample(current.aftermath, keep: 4)
                continue
            }
            if current.breadcrumbs.count > 4 {
                current.breadcrumbs = Array(current.breadcrumbs.suffix(4))
                continue
            }
            if current.repairs.count > 4 {
                current.repairs = Array(current.repairs.suffix(4))
                continue
            }
            current.during = []
            current.prelude = Array(current.prelude.suffix(2))
            current.aftermath = Array(current.aftermath.suffix(2))
        }
        return current
    }

    private static func encodedSize(_ bundle: FeedIncidentBundle) -> Int {
        (try? FeedIncidentCoding.encoder().encode(bundle).count) ?? Int.max
    }
}

/// Shell owner for feed-incident persistence. Core records in memory; this type
/// writes on a utility queue. Never call from a receive, decode, display, or
/// fatal-signal handler except via the ingest methods, which return immediately.
///
/// Coordinator hooks (camera session / decoder / chrome):
/// - `install()` once at diagnostic boot (marks leftover open incidents interrupted)
/// - `beginSession(_:)` when a live session identity is known
/// - `endSession(now:)` on explicit disconnect
/// - `ingestSnapshot(_:)` at 1 Hz with allowlisted stage counters
/// - `recordBreadcrumb(_:)` Settings enter/exit, assist, scene, surface, decoder, path, command category
/// - `recordRepair(_:)` requested / blocked / locallySent / peerResponse / pictureRestored
/// - `noteDecoderGeneration(_:)` / `noteSocketGeneration(_:)`
/// - `noteExhausted(now:)` when the repair owner spends its budget
/// - `noteUnexpectedDisconnect(now:)` for BLE/path loss before ages exist
/// - `reportExtras()` from Share Diagnostics (journal-independent)
/// One journal per app run, attributed to the single owned connection; nothing here feeds a
/// camera command, a control decision or another session's state.
public final class FeedIncidentRuntime: @unchecked Sendable {
    private let reporting: ReliabilityReporting
    private let directory: URL?
    private let queue = DispatchQueue(label: "opv.feed-incident", qos: .utility)
    private let gate = NSLock()
    private let extrasLock = NSLock()
    private var recorder = FeedIncidentRecorder()
    private var store: FeedIncidentStore?
    private var latestSnapshot: FeedIncidentSnapshot?
    private var snapshotScheduled = false
    private var pendingDecoderGeneration: Int?
    private var pendingSocketGeneration: Int?
    private var sessionContext: FeedIncidentSessionContext?
    private var lastSummaryCheckpoint: TimeInterval = 0
    private var extrasCache: [(name: String, body: String)] = []
    /// Queue-confined export of the incident bundles on disk; nil reloads them.
    private var storeExtras: [(name: String, body: String)]?

    /// `directory` holds the incident spool (nil when the app has no documents directory).
    public init(reporting: ReliabilityReporting, directory: URL?) {
        self.reporting = reporting
        self.directory = directory
    }

    public func install() {
        queue.async { [self] in
            _ = preparedStore()
            _ = try? store?.markInterrupted(now: Date())
            if let root = store?.directory { FeedSessionSummaryStore.markInterrupted(root: root) }
            let directory = directory
            let product = reporting.host.listingName
            reporting.setFinalizedSpoolLoader {
                guard let directory else { return [] }
                return FeedIncidentStore(directory: directory, product: product).loadAll().filter {
                    ReliabilityReporting.isFinalized($0)
                }
            }
            reporting.setSessionSummaryLoader {
                guard let directory else { return [] }
                return FeedSessionSummaryStore.load(root: directory).filter { $0.outcome != "live" }
            }
            refreshExtrasCache()
            reporting.enqueueFinalizedFromSpool()
        }
    }

    public func beginSession(_ context: FeedIncidentSessionContext) {
        queue.async { [self] in
            persist(recorder.beginSession(context))
            reporting.enqueueFinalizedFromSpool()
            sessionContext = context
            lastSummaryCheckpoint = 0
            persistSessionSummary(outcome: "live")
        }
    }

    public func endSession(now: TimeInterval) {
        queue.async { [self] in
            persist(recorder.endSession(now: now))
            persistSessionSummary(
                outcome: Self.summaryOutcome(
                    incidentCount: recorder.incidentCount,
                    exposure: recorder.healthyExposureSeconds))
            reporting.enqueueFinalizedFromSpool()
            sessionContext = nil
        }
    }

    /// Latest-wins 1 Hz ingest. Does not enqueue one disk write per snapshot.
    public func ingestSnapshot(_ snapshot: FeedIncidentSnapshot) {
        gate.lock()
        latestSnapshot = snapshot
        let schedule = !snapshotScheduled
        snapshotScheduled = true
        gate.unlock()
        if schedule {
            queue.async { [self] in drainSnapshot() }
        }
    }

    public func recordBreadcrumb(_ breadcrumb: FeedIncidentBreadcrumb) {
        queue.async { [self] in
            recorder.recordBreadcrumb(breadcrumb)
            reporting.noteBreadcrumb(breadcrumb)
        }
    }

    public func recordRepair(_ repair: FeedRepairRecord) {
        queue.async { [self] in
            persist(recorder.recordRepair(repair))
            reporting.noteRepair(repair)
        }
    }

    public func noteTestSource(_ source: FeedIncidentTestSource) {
        queue.async { [self] in
            recorder.noteTestSource(source)
            if var context = sessionContext, source.rank > context.testSource.rank {
                context.testSource = source
                sessionContext = context
            }
        }
    }

    public func noteDecoderGeneration(_ generation: Int) {
        scheduleGeneration { pendingDecoderGeneration = generation }
    }

    public func noteSocketGeneration(_ generation: Int) {
        scheduleGeneration { pendingSocketGeneration = generation }
    }

    public func noteExhausted(now: TimeInterval) {
        queue.async { [self] in persist(recorder.noteExhausted(now: now)) }
    }

    public func noteUnexpectedDisconnect(now: TimeInterval) {
        queue.async { [self] in persist(recorder.noteUnexpectedDisconnect(now: now)) }
    }

    /// Memory snapshot of extras. Does not wait on disk.
    public func reportExtras() -> [(name: String, body: String)] {
        extrasLock.lock()
        let copy = extrasCache
        extrasLock.unlock()
        return copy
    }

    /// Removes local incident bundles. Does not purge the SDK cache.
    public func deleteStoredIncidents(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            try? preparedStore()?.deleteAll()
            if let root = store?.directory { FeedSessionSummaryStore.deleteAll(root: root) }
            if let dir = preparedStore()?.directory {
                try? FileManager.default.removeItem(
                    at: dir.appendingPathComponent("session-summary.json"))
            }
            storeExtras = nil
            extrasLock.lock()
            extrasCache = []
            extrasLock.unlock()
            DispatchQueue.main.async { completion() }
        }
    }

    public static func summaryOutcome(incidentCount: Int, exposure: TimeInterval) -> String {
        if incidentCount > 0 { return "ended" }
        if exposure > 0 { return "healthy" }
        return "no-exposure"
    }

    public func seedExtrasCacheForTests(_ extras: [(name: String, body: String)]) {
        extrasLock.lock()
        extrasCache = extras
        extrasLock.unlock()
    }

    private func scheduleGeneration(_ update: () -> Void) {
        gate.lock()
        update()
        let schedule = !snapshotScheduled
        snapshotScheduled = true
        gate.unlock()
        if schedule {
            queue.async { [self] in drainSnapshot() }
        }
    }

    private func drainSnapshot() {
        gate.lock()
        let snapshot = latestSnapshot
        latestSnapshot = nil
        let decoderGen = pendingDecoderGeneration
        pendingDecoderGeneration = nil
        let socketGen = pendingSocketGeneration
        pendingSocketGeneration = nil
        snapshotScheduled = false
        gate.unlock()
        if let decoderGen { recorder.noteDecoderGeneration(decoderGen) }
        if let socketGen { recorder.noteSocketGeneration(socketGen) }
        if let snapshot {
            persist(recorder.recordSnapshot(snapshot))
            if snapshot.monotonicNow - lastSummaryCheckpoint >= 30 {
                lastSummaryCheckpoint = snapshot.monotonicNow
                persistSessionSummary(outcome: "live")
            }
        }
    }

    private func persist(_ job: FeedIncidentPersistenceJob?) {
        guard let job = job, let store = preparedStore() else { return }
        try? store.persist(job)
        storeExtras = nil
        refreshExtrasCache()
    }

    private func persistSessionSummary(outcome: String) {
        guard let summary = currentSessionSummary(outcome: outcome) else { return }
        guard let dir = preparedStore()?.directory else { return }
        FeedSessionSummaryStore.persist(summary, root: dir)
        // Summaries live outside the incident bundles, so the 30 s live checkpoint
        // does not reload and re-decode every stored incident.
        refreshExtrasCache()
        if summary.outcome != "live" { reporting.noteSessionSummary(summary) }
    }

    private func currentSessionSummary(outcome: String? = nil) -> FeedIncidentSessionSummary? {
        guard let sessionContext else { return nil }
        return FeedIncidentSessionSummary(
            sessionID: sessionContext.sessionID,
            healthyExposureSeconds: recorder.healthyExposureSeconds,
            incidentCount: recorder.incidentCount,
            outcome: outcome
                ?? recorder.openHeader?.outcome.rawValue
                ?? Self.summaryOutcome(
                    incidentCount: recorder.incidentCount,
                    exposure: recorder.healthyExposureSeconds),
            sourceRevision: sessionContext.sourceRevision,
            appVersion: sessionContext.appVersion, appBuild: sessionContext.appBuild,
            testSource: sessionContext.testSource,
            buildIdentity: sessionContext.buildIdentity)
    }

    private func refreshExtrasCache() {
        if storeExtras == nil { storeExtras = preparedStore()?.exportExtras() }
        var extras = storeExtras ?? []
        if let summary = currentSessionSummary(),
            let data = try? FeedIncidentCoding.encoder().encode(summary),
            let body = String(data: data, encoding: .utf8)
        {
            extras.append(("session-summary.json", body))
        }
        extrasLock.lock()
        extrasCache = extras
        extrasLock.unlock()
    }

    private func preparedStore() -> FeedIncidentStore? {
        if let store = store { return store }
        guard let directory else { return nil }
        let created = FeedIncidentStore(directory: directory, product: reporting.host.listingName)
        store = created
        return created
    }
}
