import Foundation

public struct RelayHostSourcePolicy: Sendable {
    public let encodingDepth: Int
    public let stateInterval: TimeInterval
    public let metricsInterval: TimeInterval
    public let bitrate: RelayBitratePolicy
    public let starvation: RelayCameraStarvationPolicy
    public let encoderFailureReason: String
    public init(
        encodingDepth: Int = 2, stateInterval: TimeInterval = 0.2,
        metricsInterval: TimeInterval = 5, bitrate: RelayBitratePolicy = .init(),
        starvation: RelayCameraStarvationPolicy,
        encoderFailureReason: String
    ) {
        precondition(encodingDepth > 0 && stateInterval >= 0 && metricsInterval > 0)
        self.encodingDepth = encodingDepth
        self.stateInterval = stateInterval
        self.metricsInterval = metricsInterval
        self.bitrate = bitrate
        self.starvation = starvation
        self.encoderFailureReason = encoderFailureReason
    }
}

/// Bounded source retention starts on the producer thread, before dispatch. Cadence, adaptation
/// and one-use native completions share the real host source; SDK encode and metadata are ports.
public final class RelayHostSourcePipeline<
    Codec: RelayWireCodec, Input: Sendable, Output: Sendable, Context: Sendable
>: @unchecked Sendable {
    public typealias Completion = @Sendable (Output?, Bool) -> Void
    public var onBitrate: ((Int) -> Void)?
    public var onFailure: ((String) -> Void)?
    public var onMetrics: ((Int, Int, Int, Int, Int, Double?) -> Void)?
    public private(set) var failed = false
    public var bitsPerSecond: Int { bitrate.bitsPerSecond }
    private let session: RelayHostSession<Codec>
    private let policy: RelayHostSourcePolicy
    private let execute: (@escaping @Sendable () -> Void) -> Void
    private let now: () -> TimeInterval
    private let encode: (Input, Bool, @escaping Completion) -> Void
    private let metadata: (Output, Context, Bool, TimeInterval) -> Codec.FrameMetadata
    private let image: (Output) -> Data
    private let isRecording: (Codec.State) -> Bool
    private let lock = NSLock()
    private var work: RelayBroadcastStages
    private var admittedSource: UUID
    private var bitrate: WatcherRelayBitrate
    private var recording = false
    private var measuredFPS: Double?
    private var baselineFPS: Double?
    private var lastStateAt: TimeInterval = -.infinity
    private var lastMetricsAt: TimeInterval = 0
    public init(
        session: RelayHostSession<Codec>, policy: RelayHostSourcePolicy,
        now: @escaping () -> TimeInterval,
        execute: @escaping (@escaping @Sendable () -> Void) -> Void,
        encode: @escaping (Input, Bool, @escaping Completion) -> Void,
        metadata: @escaping (Output, Context, Bool, TimeInterval) -> Codec.FrameMetadata,
        image: @escaping (Output) -> Data,
        isRecording: @escaping (Codec.State) -> Bool
    ) {
        self.session = session
        self.policy = policy
        self.now = now
        self.execute = execute
        self.encode = encode
        self.metadata = metadata
        self.image = image
        self.isRecording = isRecording
        work = RelayBroadcastStages(encodingDepth: policy.encodingDepth)
        admittedSource = session.source
        bitrate = WatcherRelayBitrate(now: now(), policy: policy.bitrate)
    }
    public func begin(ceilingIndex: Int) {
        lock.lock()
        work.replace()
        admittedSource = session.source
        lock.unlock()
        baselineFPS = nil
        measuredFPS = nil
        lastStateAt = -.infinity
        lastMetricsAt = 0
        failed = false
        bitrate = WatcherRelayBitrate(
            ceilingIndex: ceilingIndex, now: now(), policy: policy.bitrate)
        onBitrate?(bitrate.bitsPerSecond)
    }
    public func retireSource() {
        lock.lock()
        work.replace()
        admittedSource = session.source
        lock.unlock()
        recording = false
        baselineFPS = nil
        measuredFPS = nil
        lastStateAt = -.infinity
    }
    public func stop() {
        lock.lock()
        work.close()
        lock.unlock()
    }
    public func setCeiling(_ index: Int) {
        bitrate.ceilingIndex = index
        onBitrate?(bitrate.bitsPerSecond)
    }
    public func submit(_ input: Input, context: Context) {
        lock.lock()
        let ticket = work.admit(.encoding)
        let source = admittedSource
        lock.unlock()
        guard let ticket else { return }
        execute { [weak self] in
            guard let self else { return }
            guard self.current(ticket, source: source), self.session.hasPeerReadyForFrame else {
                _ = self.complete(ticket)
                return
            }
            let recording = self.recording
            self.encode(input, self.session.needsKeyframe) { [weak self] output, failed in
                self?.execute { [weak self] in
                    guard let self, self.current(ticket, source: source), self.complete(ticket)
                    else { return }
                    if failed {
                        self.failed = true
                        self.stop()
                        self.onFailure?(self.policy.encoderFailureReason)
                        return
                    }
                    guard let output else { return }
                    self.session.broadcast(
                        metadata: self.metadata(output, context, recording, self.now()),
                        image: self.image(output), admittedSource: source)
                }
            }
        }
    }
    public func update(state: Codec.State, measuredCameraFPS: Double?) {
        recording = isRecording(state)
        measuredFPS = measuredCameraFPS
        if let measuredCameraFPS, measuredCameraFPS > 0 {
            baselineFPS = max(baselineFPS ?? measuredCameraFPS, measuredCameraFPS)
        }
        let starving =
            measuredCameraFPS.flatMap { $0 > 0 ? $0 : nil }.map {
                $0 < policy.starvation.threshold(soloBaselineFPS: baselineFPS ?? $0)
            } ?? (baselineFPS != nil)
        session.acceptLatest(state: state)
        let now = now()
        if session.watcherCount > 0 {
            if let bps = bitrate.recordTick(
                saturated: session.allAuthorizedPeersFull, cameraStarving: starving, now: now)
            {
                onBitrate?(bps)
            }
            if now - lastMetricsAt >= policy.metricsInterval {
                lastMetricsAt = now
                onMetrics?(
                    session.watcherCount, bitrate.bitsPerSecond, session.sentFrames,
                    session.skippedFrames, session.keyframes, measuredFPS)
                session.clearMetrics()
            }
        }
        if now - lastStateAt >= policy.stateInterval {
            lastStateAt = now
            session.broadcast(state: state)
        }
    }
    private func current(_ ticket: RelayBroadcastStages.Ticket, source: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return work.admits(ticket.stage) && admittedSource == source && session.source == source
    }
    private func complete(_ ticket: RelayBroadcastStages.Ticket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return work.complete(ticket)
    }
}
