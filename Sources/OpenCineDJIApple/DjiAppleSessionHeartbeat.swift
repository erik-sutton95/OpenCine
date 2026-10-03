import Foundation
import OpenCineDJI

/// Actual transport observations; an absent timestamp is unknown.
public struct DjiAppleHeartbeatTransport: Sendable {
    public var lastVideoAt: TimeInterval?
    public var lastSelfieFlipReplyAt: TimeInterval?
    public var lastSelfieFlipSendAt: TimeInterval?
    public var rebuilding: Bool

    public init(lastVideoAt: TimeInterval? = nil, lastSelfieFlipReplyAt: TimeInterval? = nil,
        lastSelfieFlipSendAt: TimeInterval? = nil, rebuilding: Bool = false) {
        self.lastVideoAt = lastVideoAt
        self.lastSelfieFlipReplyAt = lastSelfieFlipReplyAt
        self.lastSelfieFlipSendAt = lastSelfieFlipSendAt
        self.rebuilding = rebuilding
    }
}

/// Registration and observation on one actual or SIMULATED transport.
@MainActor
public struct DjiAppleHeartbeatEndpoint {
    public var writeBLE: (Duml.Frame) -> Void
    public var registerDatalink: () -> Void
    public var transport: () -> DjiAppleHeartbeatTransport

    public init(writeBLE: @escaping (Duml.Frame) -> Void,
        registerDatalink: @escaping () -> Void,
        transport: @escaping () -> DjiAppleHeartbeatTransport) {
        self.writeBLE = writeBLE
        self.registerDatalink = registerDatalink
        self.transport = transport
    }
}

/// Host lifecycle and repair admission, separate from transport observations.
public struct DjiAppleHeartbeatContext: Sendable {
    public var live: Bool
    public var ownedConnection: Bool
    public var pathReady: Bool
    public var sceneActive: Bool
    public var holdsMonitor: Bool
    public var browsingMedia: Bool
    public var sessionRecovering: Bool
    public var foregroundChecking: Bool
    public var feedRepairing: Bool
    public var formatPoking: Bool

    public init(live: Bool = false, ownedConnection: Bool = false, pathReady: Bool = false,
        sceneActive: Bool = false, holdsMonitor: Bool = false, browsingMedia: Bool = false,
        sessionRecovering: Bool = false, foregroundChecking: Bool = false,
        feedRepairing: Bool = false, formatPoking: Bool = false) {
        self.live = live; self.ownedConnection = ownedConnection; self.pathReady = pathReady
        self.sceneActive = sceneActive; self.holdsMonitor = holdsMonitor
        self.browsingMedia = browsingMedia; self.sessionRecovering = sessionRecovering
        self.foregroundChecking = foregroundChecking; self.feedRepairing = feedRepairing
        self.formatPoking = formatPoking
    }
}

/// Date ages and monotonic path grace retain their distinct native clock meanings.
@MainActor
public struct DjiAppleHeartbeatTiming {
    public var wallNow: () -> TimeInterval
    public var uptime: () -> TimeInterval
    public var schedule: (Duration, @escaping @MainActor @Sendable () -> Void) -> Void

    public init(wallNow: @escaping () -> TimeInterval, uptime: @escaping () -> TimeInterval,
        schedule: @escaping (Duration, @escaping @MainActor @Sendable () -> Void) -> Void) {
        self.wallNow = wallNow; self.uptime = uptime; self.schedule = schedule
    }

    public static var continuous: Self {
        .init(wallNow: { Date.timeIntervalSinceReferenceDate },
            uptime: { ProcessInfo.processInfo.systemUptime }, schedule: { delay, wake in
                Task.detached {
                    try? await Task.sleep(for: delay)
                    await wake()
                }
            })
    }
}

/// One connection's registration lifetime and camera-path grace. Native picture policy stays in its host.
@MainActor
public final class DjiAppleSessionHeartbeat {
    public enum Event: Equatable {
        case cameraPathLost
        case heldMonitorMaintenance
        case liveMonitorMaintenance
    }

    public var endpoint: DjiAppleHeartbeatEndpoint {
        didSet { endpointGeneration &+= 1 }
    }
    private var endpointGeneration: UInt64 = 0
    private var runGeneration: UInt64 = 0
    private var wakeIdentity: UInt64 = 0
    private var pendingWake: UInt64?
    private var running = false
    private var monitorMaintenanceEnabled = false
    private var pathRecovery = CameraPathRecovery()
    private let timing: DjiAppleHeartbeatTiming
    private let context: () -> DjiAppleHeartbeatContext
    private let event: (Event) -> Void
    private let journal: (String) -> Void

    public init(endpoint: DjiAppleHeartbeatEndpoint, timing: DjiAppleHeartbeatTiming = .continuous,
        context: @escaping () -> DjiAppleHeartbeatContext, event: @escaping (Event) -> Void,
        journal: @escaping (String) -> Void = { _ in }) {
        self.endpoint = endpoint; self.timing = timing; self.context = context
        self.event = event; self.journal = journal
    }

    public func start(monitorMaintenanceEnabled: Bool) {
        stop()
        running = true
        self.monitorMaintenanceEnabled = monitorMaintenanceEnabled
        schedule(after: .zero, run: runGeneration)
    }

    /// Local retirement only. Transport close and motion cleanup belong to the actual owner.
    public func stop() {
        runGeneration &+= 1
        running = false
        pendingWake = nil
        pathRecovery.reset()
    }

    public func resetPathGrace() { pathRecovery.reset() }

    private func schedule(after delay: Duration, run: UInt64) {
        wakeIdentity &+= 1
        let wake = wakeIdentity
        pendingWake = wake
        timing.schedule(delay) { [weak self] in
            guard let self, self.running, self.runGeneration == run,
                self.pendingWake == wake else { return }
            self.pendingWake = nil
            self.tick(run: run)
        }
    }

    private func tick(run: UInt64) {
        let endpointID = endpointGeneration
        let target = endpoint
        defer {
            if running, runGeneration == run { schedule(after: .seconds(1), run: run) }
        }
        let host = context()
        let wire = target.transport()
        guard running, runGeneration == run, endpointGeneration == endpointID else { return }
        let videoFresh = wire.lastVideoAt.map { timing.wallNow() - $0 < FeedWatchdog.stallThreshold } == true
        if pathRecovery.tick(now: timing.uptime(), pathReady: host.pathReady, videoFresh: videoFresh,
            sessionActive: host.live && host.sceneActive && !host.holdsMonitor
                && !host.sessionRecovering && host.ownedConnection,
            repairInFlight: host.feedRepairing || wire.rebuilding
                || host.foregroundChecking || host.formatPoking) {
            stop()
            journal("session: camera network absent after reassociation grace; video stale")
            event(.cameraPathLost)
            return
        }
        // Camera video stops after missing app registration, even when telemetry remains fresh.
        // Scene, covers, held picture and repair cannot gate this native registration.
        target.writeBLE(Commands.sessionKeepalive())
        guard running, runGeneration == run, endpointGeneration == endpointID else { return }
        target.registerDatalink()
        guard running, runGeneration == run, endpointGeneration == endpointID,
            monitorMaintenanceEnabled else { return }
        let maintenanceHost = context()
        if maintenanceHost.holdsMonitor {
            event(.heldMonitorMaintenance)
            guard running, runGeneration == run, endpointGeneration == endpointID else { return }
        }
        let activeHost = context()
        guard !activeHost.holdsMonitor, activeHost.sceneActive, !activeHost.foregroundChecking else { return }
        event(.liveMonitorMaintenance)
        guard running, runGeneration == run, endpointGeneration == endpointID else { return }
        // Gallery/picture maintenance may synchronously change browse policy or receive a reply.
        let browsing = context().browsingMedia
        let afterMaintenance = target.transport()
        let now = timing.wallNow()
        let rxAge = afterMaintenance.lastSelfieFlipReplyAt.map { now - $0 }
        let txAge = afterMaintenance.lastSelfieFlipSendAt.map { now - $0 }
        let rx = rxAge.map { String(format: "%.1f", $0) } ?? "\u{2014}"
        let tx = txAge.map { String(format: "%.1f", $0) } ?? "\u{2014}"
        let fallback = !browsing && (rxAge == nil || rxAge! >= 2)
        journal("flip: beat tx=\(tx)s rx=\(rx)s ble-fallback=\(fallback ? 1 : 0)")
        guard running, runGeneration == run, endpointGeneration == endpointID else { return }
        if fallback { target.writeBLE(Commands.getSelfieFlip()) }
    }
}
