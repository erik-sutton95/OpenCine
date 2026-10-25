import Foundation
import OpenCineDJI

/// Varying native discovery only; saved-identity enrichment remains the host's policy.
@MainActor
public struct DjiAppleRecoveryDiscovery {
    public var waitUntilPoweredOn: () async -> Bool
    public var scan: () -> AsyncStream<DJISighting>
    public var stopScan: () -> Void
    public var enrich: (DJISighting) -> DJISighting

    public init(waitUntilPoweredOn: @escaping () async -> Bool,
        scan: @escaping () -> AsyncStream<DJISighting>, stopScan: @escaping () -> Void,
        enrich: @escaping (DJISighting) -> DJISighting) {
        self.waitUntilPoweredOn = waitUntilPoweredOn; self.scan = scan
        self.stopScan = stopScan; self.enrich = enrich
    }
}


/// Monotonic deadlines, storm uptime and wall source timestamps stay distinct clocks.
public typealias DjiAppleRecoveryTiming = SessionRecoveryEpisode.Timing

/// DJI's transport for the shared `SessionRecoveryEpisode` over the actual connection owner:
/// the advertisement scan, saved-identity enrichment, native preparation and the connection run.
/// Admission, attempts, deadlines, the budget, the storm pause and the picture proof are the
/// shared runner's. Native source, credentials, permissions, motion teardown and picture
/// publication remain typed host actions.
@MainActor
public final class DjiAppleRecoveryEpisode {
    public enum Stage: Equatable, Sendable { case joiningWiFi, openingDatalink, live, other }
    public struct Context: Sendable {
        /// Explicit transport authority, independent of decoder ownership. Unknown refuses.
        public var ownsConnection: Bool?
        public var stage: Stage?
        public var sourceAt: TimeInterval?
        public var presentedAt: TimeInterval?
        public init(ownsConnection: Bool? = nil, stage: Stage? = nil,
            sourceAt: TimeInterval? = nil, presentedAt: TimeInterval? = nil) {
            self.ownsConnection = ownsConnection; self.stage = stage
            self.sourceAt = sourceAt; self.presentedAt = presentedAt
        }
    }
    public typealias Snapshot = SessionRecoveryEpisode.Snapshot
    public typealias Cleanup = SessionRecoveryEpisode.Cleanup
    public typealias Attempt = SessionRecoveryEpisode.Attempt
    @MainActor public struct NativeActions {
        public var observe: () -> Context
        public var cleanup: (Cleanup, Attempt) -> Void
        public var scanning: (Attempt) -> Void
        /// Performs native preparation, never the pairing/AP/station/handshake workflow.
        public var prepare: (DJISighting, Attempt) -> DJIConnectionRoute?
        public init(observe: @escaping () -> Context,
            cleanup: @escaping (Cleanup, Attempt) -> Void, scanning: @escaping (Attempt) -> Void,
            prepare: @escaping (DJISighting, Attempt) -> DJIConnectionRoute?) {
            self.observe = observe; self.cleanup = cleanup; self.scanning = scanning
            self.prepare = prepare
        }
    }

    /// DJI's attempt bounds: the whole automatic budget, and a ceiling per transport stage.
    public static let attemptDeadline = SessionRecoveryEpisode.AttemptDeadline(
        attempt: .seconds(SessionRecoveryPolicy.automaticRecoveryBudgetSeconds),
        stages: [
            .joiningNetwork: deadline(for: .joiningWiFi), .openingLink: deadline(for: .openingDatalink),
            .live: deadline(for: .live), .connecting: deadline(for: .other),
        ])

    private let connectionRun: DjiAppleConnectionRun
    private let discovery: DjiAppleRecoveryDiscovery
    private let native: NativeActions
    private let timing: DjiAppleRecoveryTiming
    private let changed: (Snapshot, UUID?) -> Void
    private lazy var episode = SessionRecoveryEpisode(
        port: .init(
            observe: { [unowned self] in observation() },
            cleanup: { [unowned self] kind, attempt in cleanup(kind, attempt) },
            connect: { [unowned self] attempt in try await connect(attempt) },
            currentRun: { [unowned self] in connectionRun.currentRunID },
            retireRun: { [unowned self] in connectionRun.retire() }),
        attemptDeadline: Self.attemptDeadline, timing: timing, changed: changed)
    public var snapshot: Snapshot { episode.snapshot }
    public var currentEpisodeID: UUID? { episode.currentEpisodeID }
    public var isRunning: Bool { episode.isRunning }

    public init(connectionRun: DjiAppleConnectionRun, discovery: DjiAppleRecoveryDiscovery,
        native: NativeActions, timing: DjiAppleRecoveryTiming = .continuous,
        changed: @escaping (Snapshot, UUID?) -> Void) {
        self.connectionRun = connectionRun; self.discovery = discovery; self.native = native
        self.timing = timing; self.changed = changed
    }

    @discardableResult
    public func begin(targetID: String?, trigger: SessionRecoveryTrigger, reason: String) -> Bool {
        episode.begin(targetID: targetID, trigger: trigger, reason: reason)
    }

    /// Local retirement only; native disconnect/decoder teardown remains the host action.
    public func cancel(clearHold: Bool = true) { episode.cancel(clearHold: clearHold) }

    @discardableResult public func retry() -> Bool { episode.retry() }

    /// The app left the foreground: attempts wait and the budget's clock stops (shared episode).
    public func pause() { episode.pause() }

    /// The app is back: a paused episode dials and its budget clock runs again.
    public func resume() { episode.resume() }

    public static func deadline(for stage: Stage?) -> Duration {
        switch stage {
        case .joiningWiFi: .seconds(CameraSoftAPSwitch.joinDeadlineSeconds + 15)
        case .openingDatalink: .seconds(50)
        case .live: .seconds(2 * CameraSoftAP.foregroundPictureGrace)
        case .other, nil: .seconds(30)
        }
    }

    private func observation() -> SessionRecoveryEpisode.Observation {
        let context = native.observe()
        // Only a live stream's picture can prove the attempt; a stopped run before live failed.
        let live = context.stage == .live
        let stage: SessionRecoveryEpisode.Stage =
            switch context.stage {
            case .joiningWiFi: .joiningNetwork
            case .openingDatalink: .openingLink
            case .live: .live
            case .other, nil: .connecting
            }
        return .init(
            ownsConnection: context.ownsConnection,
            progress: !connectionRun.isRunning && !live ? .failed : .running, stage: stage,
            sourceAt: live ? context.sourceAt : nil, presentedAt: live ? context.presentedAt : nil)
    }

    private func cleanup(_ kind: Cleanup, _ attempt: Attempt) {
        native.cleanup(kind, attempt)
        // A failed or spent attempt also releases its scanner.
        if kind == .failedAttempt || kind == .budgetExhausted, attempt.isCurrent { discovery.stopScan() }
    }

    private func stopScan(_ attempt: Attempt) throws {
        try attempt.checkCurrent(); discovery.stopScan(); try attempt.checkCurrent()
    }

    /// Admits one attempt: the target's advertisement, then native preparation and a replaced
    /// connection run. The shared episode owns everything after admission.
    private func connect(_ attempt: Attempt) async throws -> Bool {
        native.scanning(attempt); try attempt.checkCurrent()
        guard let sighting = try await advertisement(targetID: attempt.targetID, attempt: attempt)
        else { return false }
        try attempt.checkContinuation()
        // The donor samples saved identity again at connect admission. Use that exact
        // target/model, and fence a synchronous replacement before native preparation.
        let admitted = discovery.enrich(sighting); try attempt.checkCurrent()
        guard let route = native.prepare(admitted, attempt) else { try attempt.checkCurrent(); return false }
        try attempt.checkCurrent()
        try attempt.adoptRun(connectionRun.replace(target: admitted, route: route, preservingSource: true))
        return true
    }

    private func advertisement(targetID: String, attempt: Attempt) async throws -> DJISighting? {
        try attempt.checkContinuation()
        let powered = await discovery.waitUntilPoweredOn(); try attempt.checkContinuation()
        guard powered else { return nil }
        let found = await withTaskGroup(of: DJISighting?.self) { group in
            group.addTask { @MainActor @Sendable [weak self, attempt] in
                guard let self else { return nil }
                do {
                    try attempt.checkContinuation()
                    let stream = self.discovery.scan(); try attempt.checkCurrent()
                    for await sighting in stream {
                        try attempt.checkContinuation()
                        let saved = self.discovery.enrich(sighting); try attempt.checkCurrent()
                        if saved.id == targetID { return saved }
                    }
                } catch {}
                return nil
            }
            group.addTask { @MainActor @Sendable [weak self, attempt] in
                guard let self else { return nil }
                do {
                    try attempt.checkContinuation()
                    try await self.timing.sleep(.seconds(30)); try attempt.checkContinuation()
                } catch {}
                return nil
            }
            let first = await group.next() ?? nil; group.cancelAll(); return first
        }
        try attempt.checkContinuation()
        // A matching camera needs the next advertisement for GATT; retain its scanner.
        if found == nil { try stopScan(attempt) }
        return found
    }
}

extension SessionRecoveryEpisode.Attempt {
    /// Native teardown calls this at its original run-retirement point. It cannot retire a
    /// successor, even if that successor is connected to the same camera.
    @discardableResult public func retireCapturedConnectionRun() -> Bool { retireCapturedRun() }
}
