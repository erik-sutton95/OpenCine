import Foundation
import OpenCineCore

/// Current preview demand. Picture ownership belongs to the native presentation runtime;
/// this value controls only Nikon's camera stream and its header/control carrier.
public struct NikonPreviewDemand: Equatable, Sendable {
    public enum Mode: Sendable {
        case picture
        case headerOnly
        case covered
        case controlOnly
    }
    public var mode: Mode
    public var size: UInt8
    public var compression: UInt8

    public init(mode: Mode, size: UInt8, compression: UInt8) {
        self.mode = mode
        self.size = size
        self.compression = compression
    }
}

/// One wire-stream attempt, independent of JPEG decoding, scopes, effects and screen state.
/// Its consumer reports whether the picture was decodable; headers require no picture decoder.
/// Routine mode changes drain the pending fetch instead of cancelling a kept command socket.
@MainActor
public final class NikonLiveViewPump {
    public enum Outcome: Equatable, Sendable {
        case cancelled
        case neverStarted(String)
        case stalled(String)
        /// The camera or the network ended the link (the camera closed the connection, the
        /// socket failed). Nothing more can go over it, so the caller neither restarts live view
        /// nor redials in place: a Nikon body closes a phone's link when another phone takes the
        /// camera, and only recovery, which asks who holds the camera first, may dial.
        case linkLost(String)
    }

    /// Whether `error` means the link itself is gone rather than one refused or slow operation.
    public nonisolated static func isLinkLoss(_ error: Error) -> Bool {
        if error is POSIXError { return true }
        switch error as? NativeCameraSessionError {
        case .connectionClosed?, .connectionFailed?: return true
        default: return false
        }
    }

    public struct Delivery: Sendable {
        public let first: Bool
        public let headerOnly: Bool
        public let frameCounter: Int
        public let bodyBusy: Bool
    }

    public struct Health: Sendable {
        public let lastGoodFrameAt: Date?
        public let badFrames: Int
        public let bodyBusy: Bool
    }

    private let link: any NikonMonitorLink
    private let now: @MainActor () -> Date
    private let sleep: @MainActor (Duration) async -> Void
    private var pending: Task<PTPLiveViewFrame, Error>?

    /// Tests inject a manual clock and scripted link. Production frame deadlines remain bounded.
    public init(
        link: any NikonMonitorLink,
        now: @escaping @MainActor () -> Date = Date.init,
        sleep: @escaping @MainActor (Duration) async -> Void = hostSleepUntilCancelled(for:)
    ) {
        self.link = link
        self.now = now
        self.sleep = sleep
    }

    /// Runs until a stall, first-frame failure, retirement or cancellation. `consume` publishes
    /// decoded picture or header values and returns false only when a picture is unreadable.
    /// Safe points occur after accepted frames and while covered, with interactive work first.
    public func run(
        demand: @MainActor () -> NikonPreviewDemand,
        isCurrent: @MainActor () -> Bool,
        consume: @MainActor (PTPLiveViewFrame, Delivery) async -> Bool,
        safePoint: @MainActor (_ frameCounter: Int, _ pollEveryCall: Bool) async -> Void,
        applied: @MainActor (NikonPreviewDemand) -> Void = { _ in },
        resetCadence: @MainActor () -> Void = {},
        health: @MainActor (Health) -> Void = { _ in }
    ) async -> Outcome {
        if demand().mode == .controlOnly {
            return await runControlOnly(
                demand: demand, isCurrent: isCurrent, consume: consume,
                safePoint: safePoint, applied: applied)
        }
        var started = false
        var frameCounter = 0
        var watchdog = LiveViewWatchdog()
        var busySince: Date?
        var coveredSince: Date?
        var suspended = false
        var wasCovered = false
        var headerOnly = false
        do {
            let firstDemand = demand()
            await configure(firstDemand, applied: applied)
            try await link.startLiveView()
            pending = fetch(deadline: .seconds(10))
            guard let pending else { return .cancelled }
            let first = try await pending.value
            guard current(isCurrent) else { return .cancelled }
            // The donor validates one decodable picture even on command-mode entry, then
            // switches to header-only pulls. Keep that startup and recovery evidence.
            guard
                await consume(
                    first,
                    Delivery(first: true, headerOnly: false, frameCounter: 0, bodyBusy: false))
            else { return .neverStarted("Live view returned an unreadable first frame.") }
            guard current(isCurrent) else { return .cancelled }
            started = true
            watchdog.recordGoodFrame(at: now(), signature: LiveFrameSignature.of(first.jpeg))
            self.pending = fetch(deadline: steadyDeadline)
            while current(isCurrent) {
                let requested = demand()
                if requested.mode == .covered {
                    wasCovered = true
                    await drain()
                    if coveredSince == nil { coveredSince = now() }
                    if !suspended, now().timeIntervalSince(coveredSince ?? now()) >= 30 {
                        suspended = true
                        await link.stopLiveView()
                    }
                    if !suspended { _ = try? await link.liveViewFrame(deadline: .seconds(2)) }
                    guard current(isCurrent) else { return .cancelled }
                    await safePoint(frameCounter, true)
                    await sleep(.milliseconds(250))
                    continue
                }
                coveredSince = nil
                if wasCovered {
                    wasCovered = false
                    if suspended {
                        suspended = false
                        await configure(requested, applied: applied)
                        do {
                            try await link.startLiveView()
                        } catch {
                            await sleep(.milliseconds(600))
                            guard current(isCurrent) else { return .cancelled }
                            try await link.startLiveView()
                        }
                    }
                    headerOnly = requested.mode == .headerOnly
                    watchdog.recordGoodFrame(at: now())
                    resetCadence()
                    self.pending = fetch(deadline: .seconds(10))
                }
                if (requested.mode == .headerOnly) != headerOnly {
                    headerOnly = requested.mode == .headerOnly
                    await drain()
                    guard current(isCurrent) else { return .cancelled }
                    await link.stopLiveView()
                    await configure(requested, applied: applied)
                    try await link.startLiveView()
                    watchdog.recordGoodFrame(at: now())
                    resetCadence()
                    self.pending = fetch(deadline: .seconds(10))
                }
                guard let next = self.pending else { return .cancelled }
                let frame = try await next.value
                guard current(isCurrent) else { return .cancelled }
                // Start N+1 before picture decode of N. The transport still serializes wire work.
                self.pending = fetch(deadline: steadyDeadline)
                if headerOnly {
                    watchdog.recordGoodFrame(at: now())
                    _ = await consume(
                        frame,
                        Delivery(
                            first: false, headerOnly: true, frameCounter: frameCounter,
                            bodyBusy: false))
                    guard current(isCurrent) else { return .cancelled }
                    await safePoint(frameCounter, true)
                    health(
                        Health(
                            lastGoodFrameAt: watchdog.lastGoodFrameAt, badFrames: 0, bodyBusy: false
                        ))
                    await sleep(.milliseconds(250))
                    continue
                }
                let accepted = await consume(
                    frame,
                    Delivery(
                        first: false, headerOnly: false, frameCounter: frameCounter + 1,
                        bodyBusy: busySince != nil))
                guard current(isCurrent) else { return .cancelled }
                if accepted {
                    frameCounter += 1
                    watchdog.recordGoodFrame(
                        at: now(), signature: LiveFrameSignature.of(frame.jpeg))
                    await safePoint(frameCounter, false)
                } else {
                    watchdog.recordBadFrame()
                }
                watchdog.check(at: now())
                if watchdog.status == .stalled {
                    if watchdog.isRepeatingLastFrame,
                        (try? await link.pollStillReleaseReadiness()) != nil
                    {
                        let holdStart = busySince ?? now()
                        busySince = holdStart
                        if now().timeIntervalSince(holdStart) < BodyBusyHoldPolicy.maxHoldSeconds {
                            health(
                                Health(
                                    lastGoodFrameAt: watchdog.lastGoodFrameAt,
                                    badFrames: watchdog.consecutiveBadFrames, bodyBusy: true))
                            await sleep(.seconds(BodyBusyHoldPolicy.holdPullIntervalSeconds))
                            continue
                        }
                    }
                    return .stalled(
                        watchdog.isRepeatingLastFrame ? "same frame replayed" : "no good frame")
                }
                busySince = nil
                health(
                    Health(
                        lastGoodFrameAt: watchdog.lastGoodFrameAt,
                        badFrames: watchdog.consecutiveBadFrames, bodyBusy: false))
            }
            await drain()
            return .cancelled
        } catch {
            // The unstructured pending fetch is deliberately not cancelled. Its own deadline
            // bounds retirement, and native teardown can close its transport immediately.
            guard current(isCurrent) else { return .cancelled }
            if Self.isLinkLoss(error) { return .linkLost(error.localizedDescription) }
            return started
                ? .stalled(error.localizedDescription) : .neverStarted(error.localizedDescription)
        }
    }

    /// Waits for a kept-session fetch to complete. Lending and replacement can then transfer
    /// pump ownership without a second reader and without interrupting the transaction socket.
    public func drain() async {
        let previous = pending
        pending = nil
        _ = try? await previous?.value
    }

    private func runControlOnly(
        demand: @MainActor () -> NikonPreviewDemand,
        isCurrent: @MainActor () -> Bool,
        consume: @MainActor (PTPLiveViewFrame, Delivery) async -> Bool,
        safePoint: @MainActor (Int, Bool) async -> Void,
        applied: @MainActor (NikonPreviewDemand) -> Void
    ) async -> Outcome {
        await configure(demand(), applied: applied)
        // Already-running live view is expected on HDMI entry; its not-OK answer is benign.
        try? await link.startLiveView()
        var count = 0
        while current(isCurrent), demand().mode == .controlOnly {
            count &+= 1
            pending = fetch(deadline: .seconds(6))
            if let pending, let frame = try? await pending.value, current(isCurrent) {
                _ = await consume(
                    frame,
                    Delivery(first: false, headerOnly: true, frameCounter: count, bodyBusy: false))
            }
            guard current(isCurrent) else { return .cancelled }
            await safePoint(count, false)
            await sleep(.milliseconds(40))
        }
        await drain()
        return .cancelled
    }

    private func current(_ isCurrent: @MainActor () -> Bool) -> Bool {
        !Task.isCancelled && isCurrent()
    }

    private var steadyDeadline: Duration {
        let rtt = link.readLastCommandRoundTripMilliseconds() ?? 100
        return .seconds(min(15.0, max(6.0, rtt * 25 / 1000)))
    }

    private func fetch(deadline: Duration) -> Task<PTPLiveViewFrame, Error> {
        let link = link
        return Task { try await link.liveViewFrame(deadline: deadline) }
    }

    private func configure(
        _ demand: NikonPreviewDemand, applied: @MainActor (NikonPreviewDemand) -> Void
    ) async {
        await link.configureLiveView(size: demand.size, compression: demand.compression)
        applied(demand)
    }
}
