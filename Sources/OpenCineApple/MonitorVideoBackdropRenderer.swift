#if os(iOS)
import CoreGraphics
import CoreVideo
import Foundation
import OpenCineMedia

public enum MonitorBackdropSourceIdentity: Equatable, Sendable {
    case live(token: MonitorVideoSourceToken, epoch: UInt64)
    case playback(item: MonitorPlaybackItemToken, epoch: UInt64)
}

/// A retained native picture, immutable look/placement, and its captured source authority.
/// Unguarded buffers remain usable by isolated native fixtures; actual producers supply admission.
public struct MonitorVideoBackdropSource: Equatable, @unchecked Sendable {
    public typealias Buffer = CVPixelBuffer
    public var buffer: CVPixelBuffer
    public var effects: MonitorFrameEffects
    public var frame: CGRect
    public var clip: CGRect
    public let identity: MonitorBackdropSourceIdentity?
    fileprivate let admission: (@MainActor @Sendable () -> Bool)?
    public init(buffer: CVPixelBuffer, effects: MonitorFrameEffects, frame: CGRect, clip: CGRect,
        identity: MonitorBackdropSourceIdentity? = nil, admission: (@MainActor @Sendable () -> Bool)? = nil) {
        self.buffer = buffer; self.effects = effects; self.frame = frame; self.clip = clip
        self.identity = identity; self.admission = admission
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.buffer === rhs.buffer && lhs.effects == rhs.effects && lhs.frame == rhs.frame && lhs.clip == rhs.clip && lhs.identity == rhs.identity
    }
}

/// One admission includes source selection, low-resolution display-look work,
/// four shared blur products, and pending delivery. Retained by the app owner,
/// so cancelling or remounting a view cannot overlap an unfinished job.
public final class MonitorVideoBackdropRenderer: @unchecked Sendable {
    public struct Result {
        public let snapshot: MonitorBackdropRasterSnapshot?
        public let ticket: MonitorPreviewAdmission.Ticket
        public let isUnchanged: Bool
        fileprivate let sources: [MonitorVideoBackdropSource]
    }

    private struct Input: Equatable {
        let canvasSize: CGSize
        let surroundRGB: UInt32
        // Retain the objects, not just their addresses: a released native
        // buffer's identity may be recycled for a different frame.
        let sources: [MonitorVideoBackdropSource]
        /// State FALSE / ZEBRA read outside `MonitorFrameEffects`.
        let externalLook: [MonitorBackdropLookState]
    }

    /// FALSE and ZEBRA thresholds follow the exposure ceiling (ISO and the
    /// live-tap ratchet), and FALSE paints only once its maps warm. Key that
    /// state so a held source with those looks settles instead of re-rendering
    /// at the backdrop cap. Read before rendering: a change during the render
    /// makes the next comparison miss once, never keeps a stale look.
    private func externalLookState(_ sources: [MonitorVideoBackdropSource]) -> [MonitorBackdropLookState] {
        sources.compactMap { source in
            let effects = source.effects
            guard effects.falseColor || effects.zebra else { return nil }
            if let suppliedLookState { return suppliedLookState(effects) }
            let maps = effects.falseColor ? imageRenderer.falseColorMapper.overlayPairData(
                scale: effects.falseColorScale.liveScale, transfer: effects.transfer,
                rec709: effects.falseColorRec709, clipByte: effects.resolvedClipByte)?.clipByte : 0
            return .init(clipByte: effects.resolvedClipByte, mapClipByte: maps)
        }
    }

    private struct CachedResult {
        let owner: UUID
        let input: Input
        let snapshot: MonitorBackdropRasterSnapshot
    }

    public typealias CacheEligibility = @Sendable (MonitorVideoBackdropSource.Buffer) -> Bool
    public typealias LookState = @Sendable (MonitorFrameEffects) -> MonitorBackdropLookState
    public typealias Operation =
        @Sendable (CGSize, [MonitorVideoBackdropSource]) -> MonitorBackdropRasterSnapshot?
    private let queue = DispatchQueue(label: "opv.monitor-backdrop", qos: .utility)
    private let lock = NSLock()
    private var admission = MonitorPreviewAdmission()
    private var nextAdmission: UInt64 = 0
    private var cached: CachedResult?  // lock-protected, one successful input only
    private let imageRenderer: MonitorInspectorImageRenderer
    private let products: [MonitorBackdropBlurProduct]
    private let cacheEligibility: CacheEligibility
    private let suppliedLookState: LookState?
    private lazy var backdropRenderer = MonitorBackdropRasterRenderer(products: products)
    private let operation: Operation?
    private let clock: @Sendable () -> UInt64
    private let minimumInterval: @Sendable () -> Double

    public init(
        products: [MonitorBackdropBlurProduct], lookCurves: [MonitorTransfer: [Double]],
        cacheEligibility: @escaping CacheEligibility = { _ in true },
        externalLookState: LookState? = nil,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        minimumInterval: @escaping @Sendable () -> Double = {
            MonitorBackdropRenderValues.minimumInterval
        },
        operation: Operation? = nil
    ) {
        self.products = products; self.cacheEligibility = cacheEligibility
        suppliedLookState = externalLookState
        imageRenderer = MonitorInspectorImageRenderer(lookCurves: lookCurves)
        self.clock = clock
        self.operation = operation
        self.minimumInterval = minimumInterval
    }

    public func activate(_ owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        admission.activate(owner: owner)
        cached = nil
    }

    public func deactivate(_ owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        admission.deactivate(owner: owner)
        if cached?.owner == owner { cached = nil }
    }

    @MainActor public func isCurrent(_ result: Result) -> Bool { accepts(result.sources, ticket: result.ticket) }

    @MainActor private func accepts(_ sources: [MonitorVideoBackdropSource], ticket: MonitorPreviewAdmission.Ticket) -> Bool {
        guard isCurrent(ticket) else { return false }
        for source in sources {
            guard isCurrent(ticket) else { return false }
            let accepted = source.admission?() ?? true
            guard isCurrent(ticket), accepted else { return false }
        }
        return isCurrent(ticket)
    }

    private func isCurrent(_ ticket: MonitorPreviewAdmission.Ticket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return admission.isCurrent(ticket)
    }

    private func reserve(_ owner: UUID) -> MonitorPreviewAdmission.Ticket? {
        let now = clock()
        let seconds = max(MonitorBackdropRenderValues.minimumInterval, minimumInterval())
        lock.lock()
        defer { lock.unlock() }
        guard now >= nextAdmission,
            let ticket = admission.acquire(
                owner: owner, nowNanoseconds: now, minimumIntervalNanoseconds: 0)
        else { return nil }
        nextAdmission =
            now
            &+ max(
                MonitorBackdropRenderValues.minimumIntervalNanoseconds,
                UInt64((seconds * 1_000_000_000).rounded(.up)))
        return ticket
    }

    private func complete(_ ticket: MonitorPreviewAdmission.Ticket) {
        lock.lock()
        defer { lock.unlock() }
        admission.complete(ticket)
    }

    private func cachedSnapshot(
        for input: Input, ticket: MonitorPreviewAdmission.Ticket
    ) -> MonitorBackdropRasterSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard admission.isCurrent(ticket) else { return nil }
        if cached?.input == input { return cached?.snapshot }
        // A different input must retire the old entry even if rendering fails.
        cached = nil
        return nil
    }

    private func cache(
        _ snapshot: MonitorBackdropRasterSnapshot, input: Input, owner: UUID,
        ticket: MonitorPreviewAdmission.Ticket
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard admission.isCurrent(ticket) else { return }
        cached = CachedResult(owner: owner, input: input, snapshot: snapshot)
    }

    @MainActor
    public func render(
        owner: UUID, canvasSize: CGSize, surroundRGB: UInt32 = 0x08090A,
        prepare: @MainActor () -> [MonitorVideoBackdropSource]
    ) async -> Result? {
        guard !Task.isCancelled, let ticket = reserve(owner) else { return nil }
        defer { complete(ticket) }
        let sources = prepare()
        guard accepts(sources, ticket: ticket) else { return nil }
        let result: Result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    var isUnchanged = false
                    let snapshot: MonitorBackdropRasterSnapshot? = autoreleasepool {
                        guard isCurrent(ticket) else { return nil }
                        let input = Input(
                            canvasSize: canvasSize, surroundRGB: surroundRGB, sources: sources,
                            externalLook: externalLookState(sources))
                        var canCache =
                            !sources.isEmpty
                            && sources.allSatisfy {
                                cacheEligibility($0.buffer)
                            }
                        if let previous = cachedSnapshot(for: input, ticket: ticket), canCache {
                            isUnchanged = true
                            return previous
                        }
                        guard isCurrent(ticket) else { return nil }
                        let snapshot: MonitorBackdropRasterSnapshot?
                        if let operation {
                            snapshot = operation(canvasSize, sources)
                        } else {
                            guard !sources.isEmpty else { return nil }
                            // One source: its look context renders straight into the
                            // blur canvas (no CGImage readback and re-upload per frame).
                            if sources.count == 1, let source = sources.first,
                                let look = imageRenderer.lookImage(
                                    source: source.buffer, effects: source.effects),
                                let direct = backdropRenderer.render(
                                    canvasSize: canvasSize, look: look.image, frame: source.frame,
                                    clip: source.clip, lookContext: look.context,
                                    outputColorSpace: look.outputColorSpace, surroundRGB: surroundRGB)
                            {
                                if canCache { cache(direct, input: input, owner: owner, ticket: ticket) }
                                guard isCurrent(ticket) else { return nil }
                                return direct
                            }
                            let layers = sources.compactMap { source -> MonitorBackdropRasterLayer? in
                                guard isCurrent(ticket),
                                    let image = imageRenderer.renderImage(
                                        source: source.buffer, effects: source.effects)
                                else { return nil }
                                return MonitorBackdropRasterLayer(
                                    image: image, frame: source.frame, clip: source.clip)
                            }
                            // Preserve partial-source fallback, but retry failed
                            // source renders instead of caching an incomplete stage.
                            canCache = canCache && layers.count == sources.count
                            guard isCurrent(ticket) else { return nil }
                            snapshot = backdropRenderer.render(
                                canvasSize: canvasSize, layers: layers, surroundRGB: surroundRGB)
                        }
                        if let snapshot, canCache {
                            cache(snapshot, input: input, owner: owner, ticket: ticket)
                        }
                        guard isCurrent(ticket) else { return nil }
                        return snapshot
                    }
                    continuation.resume(
                        returning: Result(
                            snapshot: snapshot, ticket: ticket, isUnchanged: isUnchanged, sources: sources))
                }
            }
        } onCancel: {
            self.deactivate(owner)
        }
        guard !Task.isCancelled, accepts(sources, ticket: ticket) else { return nil }
        return result
    }
}

#endif
