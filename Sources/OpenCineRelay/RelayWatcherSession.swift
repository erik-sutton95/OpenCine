import Foundation

/// Existing watcher cadence and presentation deadlines, independent of the transport or decoder.
public struct RelayWatcherTimingPolicy: Equatable, Sendable {
    public let pollInterval: TimeInterval
    public let fpsWindow: TimeInterval
    public let pictureWait: TimeInterval
    public let controlRequestTimeout: TimeInterval
    public init(pollInterval: TimeInterval = 0.25, fpsWindow: TimeInterval = 1,
        pictureWait: TimeInterval = 3, controlRequestTimeout: TimeInterval = 15) {
        precondition([pollInterval, fpsWindow, pictureWait, controlRequestTimeout].allSatisfy { $0.isFinite && $0 > 0 })
        self.pollInterval = pollInterval; self.fpsWindow = fpsWindow
        self.pictureWait = pictureWait; self.controlRequestTimeout = controlRequestTimeout
    }
}

public enum RelayWatcherPhase: Equatable, Sendable {
    case idle, connecting, reconnecting(Int), needsPasscode, live, failed(String)
}
public struct RelayWatcherRefusal: Equatable, Sendable {
    public let reason: String
    public let passcodeRequired: Bool
    public init(reason: String, passcodeRequired: Bool) {
        self.reason = reason; self.passcodeRequired = passcodeRequired
    }
}
public struct RelayWatcherStatus: Equatable, Sendable {
    public var phase: RelayWatcherPhase = .idle
    public var receivedFPS = 0
    public var waitingForPicture = false
    public var controlRequested = false
    public init() {}
}

/// Pure watcher decisions. One real transport owner drives this with actual native presentations.
/// A received access unit is not a presented picture and cannot refresh the picture deadline.
public struct RelayWatcherSession: Sendable {
    public private(set) var status = RelayWatcherStatus()
    public let policy: RelayWatcherTimingPolicy
    private var recovery: WatcherRelayRecovery?
    private var freshness = WatcherRelayFrameFreshness()
    private var lastPictureAt: TimeInterval?
    private var lastPresentation: TimeInterval?
    private var acceptedAt: TimeInterval?
    private var frameCount = 0
    private var fpsSince: TimeInterval = 0
    private var controlRequestedAt: TimeInterval?
    public var active: Bool { recovery != nil }
    public init(policy: RelayWatcherTimingPolicy = .init()) { self.policy = policy }

    public mutating func begin(now: TimeInterval) {
        status = .init(); status.phase = .connecting
        recovery = .init(now: now); freshness = .init()
        lastPictureAt = nil; lastPresentation = nil; acceptedAt = nil
        frameCount = 0; fpsSince = now; controlRequestedAt = nil
    }
    public mutating func beginConnection() { freshness = .init() }
    public mutating func connected(now: TimeInterval) {
        guard active else { return }
        acceptedAt = now; status.phase = .live; recovery?.connected(now: now)
    }
    public mutating func receivedState(now: TimeInterval) { recovery?.received(now: now) }
    public mutating func receivedControl(now: TimeInterval) {
        status.controlRequested = false; controlRequestedAt = nil
        recovery?.received(now: now)
    }
    public mutating func presentedPicture(presentation: TimeInterval, now: TimeInterval) {
        guard status.phase == .live, presentation.isFinite, lastPresentation != presentation else { return }
        lastPresentation = presentation; lastPictureAt = now; frameCount += 1
        recovery?.received(now: now, picture: true)
    }
    public mutating func admitsFrame(encodedAt: TimeInterval?, receivedAt: TimeInterval) -> Bool {
        status.phase == .live && !freshness.isFallingBehind(encodedAt: encodedAt, receivedAt: receivedAt)
    }
    @discardableResult public mutating func disconnected(now: TimeInterval) -> WatcherRelayRecovery.Action {
        guard active else { return .none }
        let action = recovery?.disconnected(now: now) ?? .none
        if action != .exhausted { beginReconnect() }
        return action
    }
    private mutating func beginReconnect() {
        status.phase = .reconnecting(recovery?.retryCount ?? 1)
        status.controlRequested = false; acceptedAt = nil
    }
    public mutating func tick(now: TimeInterval) -> WatcherRelayRecovery.Action {
        guard var recovery else { return .none }
        let action = recovery.tick(now: now)
        self.recovery = recovery
        if recovery.retryAt != nil, !isReconnecting { beginReconnect() }
        if now - fpsSince >= policy.fpsWindow {
            status.receivedFPS = Int((Double(frameCount) / (now - fpsSince)).rounded())
            frameCount = 0; fpsSince = now
        }
        status.waitingForPicture = status.phase == .live && now - (lastPictureAt ?? acceptedAt ?? now) >= policy.pictureWait
        if let controlRequestedAt, now - controlRequestedAt >= policy.controlRequestTimeout {
            status.controlRequested = false; self.controlRequestedAt = nil
        }
        return action
    }
    private var isReconnecting: Bool { if case .reconnecting = status.phase { return true }; return false }
    @discardableResult public mutating func requestControl(now: TimeInterval) -> Bool {
        guard status.phase == .live, !status.controlRequested else { return false }
        status.controlRequested = true; controlRequestedAt = now; return true
    }
    public mutating func denied(passcodeRequired: Bool, reason: String) {
        stopRecovery(); status.phase = passcodeRequired ? .needsPasscode : .failed(reason)
    }
    public mutating func fail(_ message: String) { stopRecovery(); status.phase = .failed(message) }
    public mutating func leave() { stopRecovery(); status.phase = .idle }
    private mutating func stopRecovery() {
        recovery?.stop(); recovery = nil; status.controlRequested = false
        controlRequestedAt = nil; status.waitingForPicture = false
    }
}
