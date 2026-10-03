import Foundation
import OpenCineDJI

/// Local host repair admission, independent of picture observation.
public struct DjiApplePictureRecoveryContext {
    public var rebuilding: Bool
    public var endpointIdentity: ObjectIdentifier?
    public var pictureIntent: Int?
    public var browsingMedia: Bool
    public var holdsMonitor: Bool
    public var sessionRecovering: Bool
    public init(rebuilding: Bool = false, endpointIdentity: ObjectIdentifier? = nil,
        pictureIntent: Int? = nil, browsingMedia: Bool = false,
        holdsMonitor: Bool = false, sessionRecovering: Bool = false) {
        self.rebuilding = rebuilding
        self.endpointIdentity = endpointIdentity
        self.pictureIntent = pictureIntent
        self.browsingMedia = browsingMedia
        self.holdsMonitor = holdsMonitor
        self.sessionRecovering = sessionRecovering
    }
}

/// Observations from one real endpoint; absent receive time is unknown.
public struct DjiApplePictureRecoveryTransport {
    public var closed: Bool
    public var lastVideoPacketAt: TimeInterval?
    public init(closed: Bool = false, lastVideoPacketAt: TimeInterval? = nil) {
        self.closed = closed
        self.lastVideoPacketAt = lastVideoPacketAt
    }
}

@MainActor public struct DjiApplePictureRecoveryEndpoint {
    public let identity: ObjectIdentifier
    public var negotiate: (String) async throws -> Void
    public var transport: () -> DjiApplePictureRecoveryTransport
    public init(identity: ObjectIdentifier, negotiate: @escaping (String) async throws -> Void,
        transport: @escaping () -> DjiApplePictureRecoveryTransport) {
        self.identity = identity
        self.negotiate = negotiate
        self.transport = transport
    }
}

/// The freshness predicate is derived by the native host from real source and presentation.
public struct DjiAppleRecoveryPicture {
    public var fresh: Bool
    public var lastPresentedAt: TimeInterval?
    public init(fresh: Bool = false, lastPresentedAt: TimeInterval? = nil) {
        self.fresh = fresh
        self.lastPresentedAt = lastPresentedAt
    }
}

@MainActor public struct DjiApplePictureRecoveryNative {
    public var prepare: () -> TimeInterval
    public var enable: () -> Void
    public var probe: () -> Void
    public var picture: (TimeInterval, TimeInterval) -> DjiAppleRecoveryPicture
    public init(prepare: @escaping () -> TimeInterval, enable: @escaping () -> Void,
        probe: @escaping () -> Void,
        picture: @escaping (TimeInterval, TimeInterval) -> DjiAppleRecoveryPicture) {
        self.prepare = prepare
        self.enable = enable
        self.probe = probe
        self.picture = picture
    }
}

/// Source observation uses wall time; the bounded wait uses monotonic time.
@MainActor public struct DjiApplePictureRecoveryTiming {
    public var wallNow: () -> TimeInterval
    public var monotonicNow: () -> TimeInterval
    public var wait: (Duration) async throws -> Void
    public init(wallNow: @escaping () -> TimeInterval,
        monotonicNow: @escaping () -> TimeInterval,
        wait: @escaping (Duration) async throws -> Void) {
        self.wallNow = wallNow
        self.monotonicNow = monotonicNow
        self.wait = wait
    }
    public static var continuous: Self {
        .init(wallNow: { Date.timeIntervalSinceReferenceDate },
            monotonicNow: { ProcessInfo.processInfo.systemUptime },
            wait: { try await Task.sleep(for: $0) })
    }
}

/// One session's serialized repair lifetime. Retirement never sends a camera command.
@MainActor
public final class DjiApplePictureRecovery {
    public enum Result: Equatable { case restored, superseded, exhausted }
    public enum Event: Equatable {
        case admitted, released, restored, holdForWatchdog(cycles: Int)
        case escalateSession, negotiationFailed(reason: String)
    }
    @MainActor public final class Attempt {
        fileprivate weak var owner: DjiApplePictureRecovery?
        fileprivate let generation: UInt64
        fileprivate init(owner: DjiApplePictureRecovery, generation: UInt64) {
            self.owner = owner
            self.generation = generation
        }
        public func repairEndpoint(_ endpoint: DjiApplePictureRecoveryEndpoint,
            reason: String, pictureIntent: Int, timeout: Duration) async -> Result {
            guard let owner, owner.isEndpointCurrent(self, endpoint: endpoint),
                let native = owner.native else { return .superseded }
            let started = native.prepare()
            guard owner.isEndpointCurrent(self, endpoint: endpoint) else { return .superseded }
            do {
                try await endpoint.negotiate(reason)
                guard owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent)
                else { return .superseded }
                native.enable()
                return await waitForPicture(endpoint, since: started,
                    pictureIntent: pictureIntent, timeout: timeout)
            } catch is CancellationError {
                return .superseded
            } catch {
                // A cover retires picture intent, not a genuine transport failure.
                guard owner.isEndpointCurrent(self, endpoint: endpoint) else { return .superseded }
                owner.event(.negotiationFailed(reason: reason))
                return owner.isEndpointCurrent(self, endpoint: endpoint) ? .exhausted : .superseded
            }
        }
        public func waitForPicture(_ endpoint: DjiApplePictureRecoveryEndpoint,
            since started: TimeInterval, pictureIntent: Int, timeout: Duration) async -> Result {
            guard let owner, let native = owner.native else { return .superseded }
            let c = timeout.components
            let deadline = owner.timing.monotonicNow()
                + Double(c.seconds) + Double(c.attoseconds) / 1e18
            var picture = DjiAppleRecoveryPicture()
            while owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent) {
                picture = native.picture(started, owner.timing.wallNow())
                guard owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent)
                else { return .superseded }
                if picture.fresh {
                    owner.event(.restored)
                    return owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent)
                        ? .restored : .superseded
                }
                guard owner.timing.monotonicNow() < deadline else { break }
                native.probe()
                guard owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent)
                else { return .superseded }
                do { try await owner.timing.wait(.milliseconds(100)) }
                catch { return .superseded }
            }
            guard owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent)
            else { return .superseded }
            let now = owner.timing.wallNow()
            let transport = endpoint.transport()
            // Injected observations can synchronously retire or replace the attempt.
            guard owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent,
                transport: transport) else { return .superseded }
            let pictureSinceLastHold = owner.lastSessionHoldAt.map { held in
                picture.lastPresentedAt.map { $0 > held } ?? false
            } ?? false
            owner.sessionHoldCycles = FeedWatchdog.nextSessionHoldCycles(
                lastVideoPacketAge: transport.lastVideoPacketAt.map { now - $0 },
                previousCycles: owner.sessionHoldCycles, pictureSinceLastCycle: pictureSinceLastHold)
            owner.lastSessionHoldAt = now
            owner.event(owner.sessionHoldCycles > 0
                ? .holdForWatchdog(cycles: owner.sessionHoldCycles) : .escalateSession)
            return owner.isPictureCurrent(self, endpoint: endpoint, intent: pictureIntent)
                ? .exhausted : .superseded
        }
    }
    public var isBusy: Bool { task != nil }
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    // Preserve the donor's per-session history across local cancellation/reset.
    private var sessionHoldCycles = 0
    private var lastSessionHoldAt: TimeInterval?
    private let context: () -> DjiApplePictureRecoveryContext
    private let native: DjiApplePictureRecoveryNative?
    private let event: (Event) -> Void
    private let timing: DjiApplePictureRecoveryTiming
    public init(context: @escaping () -> DjiApplePictureRecoveryContext,
        native: DjiApplePictureRecoveryNative? = nil,
        timing: DjiApplePictureRecoveryTiming = .continuous,
        event: @escaping (Event) -> Void = { _ in }) {
        self.context = context
        self.native = native
        self.event = event
        self.timing = timing
    }
    @discardableResult
    public func start(_ work: @escaping @MainActor (Attempt) async -> Void) -> Bool {
        guard FeedWatchdog.shouldStartFeedRecovery(
            rebuildInFlight: isBusy || context().rebuilding) else { return false }
        generation &+= 1
        let attempt = Attempt(owner: self, generation: generation)
        task = Task { @MainActor in
            guard self.isCurrent(attempt) else { return }
            await work(attempt)
            guard self.generation == attempt.generation else { return }
            self.task = nil
            self.event(.released)
        }
        event(.admitted)
        return true
    }
    public func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }
    /// Media return yields to a current repair, including a replacement's nil-driver gap.
    @discardableResult
    public func claim(pictureIntent: Int,
        work: @escaping @MainActor (Attempt) async -> Void) async -> Bool {
        while canClaim(pictureIntent), isBusy || context().rebuilding {
            do { try await timing.wait(.milliseconds(100)) }
            catch { return false }
        }
        guard canClaim(pictureIntent) else { return false }
        return start(work)
    }
    private func canClaim(_ intent: Int) -> Bool {
        let current = context()
        return !Task.isCancelled && current.pictureIntent == intent && !current.browsingMedia
            && !current.holdsMonitor && !current.sessionRecovering
    }
    private func isCurrent(_ attempt: Attempt) -> Bool {
        attempt.owner === self && generation == attempt.generation && isBusy && !Task.isCancelled
    }
    private func isEndpointCurrent(_ attempt: Attempt,
        endpoint: DjiApplePictureRecoveryEndpoint) -> Bool {
        guard isCurrent(attempt) else { return false }
        let current = context()
        return current.endpointIdentity == endpoint.identity && isCurrent(attempt)
    }
    private func isPictureCurrent(_ attempt: Attempt,
        endpoint: DjiApplePictureRecoveryEndpoint, intent: Int) -> Bool {
        guard isCurrent(attempt) else { return false }
        let transport = endpoint.transport()
        return isPictureCurrent(attempt, endpoint: endpoint, intent: intent, transport: transport)
    }
    private func isPictureCurrent(_ attempt: Attempt,
        endpoint: DjiApplePictureRecoveryEndpoint, intent: Int,
        transport: DjiApplePictureRecoveryTransport) -> Bool {
        let current = context()
        return current.endpointIdentity == endpoint.identity && !transport.closed
            && current.pictureIntent == intent && !current.browsingMedia && isCurrent(attempt)
    }
}

#if os(iOS)
extension DjiApplePictureRecoveryEndpoint {
    public init(datalink: DjiAppleDatalink) {
        self.init(identity: ObjectIdentifier(datalink), negotiate: { [weak datalink] reason in
            guard let datalink else { throw CancellationError() }
            try await datalink.rebuildUDP(reason: reason)
        }, transport: { [weak datalink] in
            .init(closed: datalink?.isClosed ?? true,
                lastVideoPacketAt: datalink?.lastVideoPacketAt?.timeIntervalSinceReferenceDate)
        })
    }
}
#endif
