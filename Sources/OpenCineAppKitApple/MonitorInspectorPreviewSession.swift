#if os(iOS)
import Foundation
import Observation
import OpenCineApple
import OpenCineMedia
import UIKit

/// A borrowed native preview source. The existing renderer retains its one-job
/// admission and the sample bus retains the live/playback publication lease.
@MainActor public struct MonitorInspectorImageSource {
    public struct Identity: Hashable {
        fileprivate let renderer: ObjectIdentifier
        fileprivate let samples: ObjectIdentifier
    }

    public struct Snapshot {
        public let source: ObjectIdentifier
        public let epoch: UInt64
        public let playback: Bool
        public let transfer: MonitorTransfer
        public let exposureCeiling: ScopeExposureCeiling
    }

    fileprivate let renderer: MonitorInspectorImageRenderer
    fileprivate let samples: LiveFrameSampleBus

    public init(renderer: MonitorInspectorImageRenderer, samples: LiveFrameSampleBus) {
        self.renderer = renderer
        self.samples = samples
    }

    public var identity: Identity {
        Identity(renderer: ObjectIdentifier(renderer), samples: ObjectIdentifier(samples))
    }

    /// Reading meaning observes source retirement, not each retained pixel buffer.
    public var snapshot: Snapshot? {
        guard let source = samples.inspectorSource else { return nil }
        return Snapshot(source: ObjectIdentifier(samples), epoch: samples.inspectorSourceEpoch,
            playback: samples.usesPlaybackSource, transfer: source.transfer,
            exposureCeiling: samples.exposureCeiling)
    }
}

/// Immutable facts from the admitted picture; no native sample bus enters UI.
@MainActor public struct MonitorInspectorImageFrame {
    fileprivate let native: LiveFrameSampleBus.InspectorFrame
    public var transfer: MonitorTransfer { native.transfer }
    public var exposureCeiling: ScopeExposureCeiling { native.lease.exposureCeiling }
}

/// Visible inspector lifetime and polling over one borrowed native renderer.
/// Changing meaning invalidates adoption without releasing a running work slot.
@MainActor @Observable public final class MonitorInspectorPreviewSession<Meaning: Equatable> {
    @ObservationIgnored private var retainedImage: CGImage?
    @ObservationIgnored private var publishedMeaning: Meaning?
    @ObservationIgnored private var notifyingImage = false
    @ObservationIgnored private var imageNotificationPending = false
    private(set) var image: CGImage? {
        get { access(keyPath: \.image); return retainedImage }
        set {
            retainedImage = newValue
            if newValue == nil { publishedMeaning = nil }
            imageNotificationPending = true
            // A nested replacement commits now and notifies after this callback unregisters.
            guard !notifyingImage else { return }
            notifyingImage = true
            defer { notifyingImage = false }
            while imageNotificationPending {
                imageNotificationPending = false
                withMutation(keyPath: \.image) {}
            }
        }
    }

    private struct Run {
        let owner: UUID
        let source: MonitorInspectorImageSource
    }
    @ObservationIgnored private var active: Run?
    @ObservationIgnored private var meaning: Meaning?
    @ObservationIgnored private var readMeaning: (@MainActor () -> Meaning?)?
    @ObservationIgnored private var prepareEffects: (@MainActor (MonitorInspectorImageFrame) -> MonitorFrameEffects)?
    @ObservationIgnored private var revision: UInt64 = 0

    public init() {}

    static var refreshInterval: Duration {
        .nanoseconds(Int64(MonitorPreviewAdmission.minimumIntervalNanoseconds))
    }

    /// The host supplies cheap meaning and defers cube preparation to native admission.
    public func synchronize(currentMeaning: @escaping @MainActor () -> Meaning?,
        effects: @escaping @MainActor (MonitorInspectorImageFrame) -> MonitorFrameEffects) {
        let owner = active?.owner, before = revision
        let meaning = currentMeaning()
        guard active?.owner == owner, revision == before else { return }
        readMeaning = currentMeaning
        prepareEffects = effects
        guard self.meaning != meaning else { return }
        self.meaning = meaning
        revision &+= 1
        if let active { active.source.renderer.invalidate(owner: active.owner) }
        image = nil
    }

    /// Bounded internal steps also let tests use a manual native clock.
    @discardableResult func activate(source: MonitorInspectorImageSource) -> UUID {
        let owner = UUID()
        let previous = active
        active = Run(owner: owner, source: source)
        revision &+= 1
        if let previous { previous.source.renderer.deactivate(owner: previous.owner) }
        image = nil
        guard isCurrent(owner) else { return owner }
        source.renderer.activate(owner: owner)
        return owner
    }

    func isCurrent(_ owner: UUID) -> Bool { active?.owner == owner }

    public func image(matching meaning: Meaning) -> CGImage? {
        let retained = image
        return publishedMeaning == meaning ? retained : nil
    }

    func deactivate(owner: UUID) {
        guard let captured = active, captured.owner == owner else { return }
        active = nil
        revision &+= 1
        meaning = nil; readMeaning = nil; prepareEffects = nil
        captured.source.renderer.deactivate(owner: owner)
        image = nil
    }

    public func deactivate() {
        if let active { deactivate(owner: active.owner) }
        else {
            revision &+= 1
            meaning = nil; readMeaning = nil; prepareEffects = nil
            image = nil
        }
    }

    func pulse(owner: UUID) async {
        guard !Task.isCancelled, let captured = active, captured.owner == owner,
            let readMeaning, let prepareEffects else { return }
        let before = revision
        let latestMeaning = readMeaning()
        guard isCurrent(owner), revision == before else { return }
        if meaning != latestMeaning {
            meaning = latestMeaning
            revision &+= 1
            captured.source.renderer.invalidate(owner: owner)
            let changed = revision
            image = nil
            guard isCurrent(owner), revision == changed else { return }
        }
        let expectedRevision = revision
        guard let meaning = latestMeaning,
            let frame = captured.source.samples.inspectorFrame else { return }
        let imageFrame = MonitorInspectorImageFrame(native: frame)
        let rendered = await captured.source.renderer.render(owner: owner, source: frame) {
            prepareEffects(imageFrame)
        }
        guard !Task.isCancelled, isCurrent(owner), revision == expectedRevision,
            self.meaning == meaning, let rendered,
            captured.source.renderer.isCurrent(rendered), frame.isCurrent else { return }
        guard let currentMeaning = self.readMeaning, currentMeaning() == meaning,
            isCurrent(owner), revision == expectedRevision, frame.isCurrent else { return }
        // Commit before observation; no old completion writes after its notification.
        publishedMeaning = meaning
        image = rendered.image
    }

    public func run(source: MonitorInspectorImageSource) async {
        guard !Task.isCancelled else { return }
        let owner = activate(source: source)
        defer { deactivate(owner: owner) }
        while !Task.isCancelled, isCurrent(owner) {
            await pulse(owner: owner)
            guard !Task.isCancelled, isCurrent(owner) else { return }
            do {
                // One serial tick; rejected work never schedules a catch-up request.
                try await Task.sleep(for: Self.refreshInterval)
            } catch { return }
        }
    }
}
#endif
