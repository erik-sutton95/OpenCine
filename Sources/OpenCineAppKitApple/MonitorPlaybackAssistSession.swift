#if os(iOS)
import AVFoundation
import Observation
import OpenCineApple
import OpenCineMedia

/// Attaches the existing meter/effects to one native frame source (the plain file owner or an
/// integration's source over the same feed). Its admission is the playback item's token; a
/// detached item's callback cannot attach to a successor.
@MainActor @Observable public final class MonitorPlaybackAssistSession: MonitorPlaybackAssistService {
    @ObservationIgnored private var currentLevels: MonitorAudioMeterLevels?
    public private(set) var audioLevels: MonitorAudioMeterLevels? {
        get { access(keyPath: \.audioLevels); return currentLevels }
        set { currentLevels = newValue; withMutation(keyPath: \.audioLevels) {} }
    }
    @ObservationIgnored private let native: any MonitorPlaybackFrameSource
    @ObservationIgnored private let samples: LiveFrameSampleBus
    @ObservationIgnored private let meter: MonitorPlaybackAudioMeterRuntime
    @ObservationIgnored private let projectEffects: @MainActor (MonitorFrameEffects) -> MonitorFrameEffects
    @ObservationIgnored private let audio: MonitorPlaybackAudioSession.Lease
    @ObservationIgnored private var token: MonitorPlaybackItemToken?
    /// The item the audio tap is attached to; retirement detaches from exactly this item.
    @ObservationIgnored private weak var attached: AVPlayerItem?
    @ObservationIgnored private let audioOwnership: (@MainActor @Sendable (Bool) -> Void)?
    @ObservationIgnored private var admission: (@MainActor () -> Bool)?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var request = UUID()
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var activated = false
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var effects = MonitorFrameEffects()

    // Retain the existing initializer entry point for current and pinned callers.
    public convenience init(native: any MonitorPlaybackFrameSource, samples: LiveFrameSampleBus,
        projectEffects: @escaping @MainActor (MonitorFrameEffects) -> MonitorFrameEffects = { $0 },
        onTapFailure: @escaping @Sendable (Int32) -> Void = { _ in },
        onAudioFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(audioSession: MonitorPlaybackAudioSession(), native: native, samples: samples,
            projectEffects: projectEffects, onTapFailure: onTapFailure,
            onAudioFailure: onAudioFailure)
    }

    /// Supply the host's retained audio session to fence predecessor/successor players.
    /// `audioOwnership` hears `true` before this player claims the audio session and `false`
    /// once its release completed.
    public init(audioSession: MonitorPlaybackAudioSession,
        native: any MonitorPlaybackFrameSource, samples: LiveFrameSampleBus,
        projectEffects: @escaping @MainActor (MonitorFrameEffects) -> MonitorFrameEffects = { $0 },
        onTapFailure: @escaping @Sendable (Int32) -> Void = { _ in },
        onAudioFailure: @escaping @Sendable (String) -> Void = { _ in },
        audioOwnership: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        self.native = native; self.samples = samples; self.projectEffects = projectEffects
        self.audioOwnership = audioOwnership
        audio = audioSession.makeLease(onFailure: { failure in onAudioFailure(failure.message) },
            onReleased: { audioOwnership?(false) })
        meter = MonitorPlaybackAudioMeterRuntime(onTapFailure: onTapFailure)
        native.onItemChanged = { [weak self] item in self?.itemChanged(item) }
    }

    public func activate() {
        guard !closed, !activated else { return }
        activated = true
        audio.activate { [audioOwnership] in audioOwnership?(true) }
    }

    public func synchronize(item: MonitorPlaybackItemToken, effects: MonitorFrameEffects,
        audioVisible: Bool, outputMuted: Bool, ifCurrent: @escaping @MainActor () -> Bool) {
        guard !closed else { return }
        request = UUID(); let invocation = request, before = revision
        guard ifCurrent(), !closed, revision == before, request == invocation else { return }
        let changed = token != item
        if changed { revision = UUID() }
        let captured = revision
        token = item; admission = ifCurrent
        if changed {
            polling = false; meter.stopPolling()
            guard current(item, revision: captured, request: invocation) else { return }
        }
        let projected = projectEffects(effects)
        guard current(item, revision: captured, request: invocation) else { return }
        activate()
        guard current(item, revision: captured, request: invocation) else { return }
        self.effects = projected
        native.feed.setEffects(projected, transfer: projected.transfer, sampleBus: samples)
        guard current(item, revision: captured, request: invocation) else { return }
        if changed, let nativeItem = native.player.currentItem { itemChanged(nativeItem) }
        guard current(item, revision: captured, request: invocation) else { return }
        // The Apple processing tap measures the clip independently of the player mute state.
        let wantsPolling = audioVisible
        if wantsPolling && !polling {
            polling = true
            meter.startPolling { [weak self] levels in
                guard let self, self.current(item, revision: captured), self.polling else { return }
                self.audioLevels = levels
            }
        } else if !wantsPolling {
            polling = false; meter.stopPolling()
            guard current(item, revision: captured, request: invocation) else { return }
            audioLevels = nil
        }
    }

    private func current(_ item: MonitorPlaybackItemToken, revision captured: UUID, request expected: UUID? = nil) -> Bool {
        guard !closed, revision == captured, token == item,
            expected == nil || request == expected, let admission else { return false }
        let admitted = admission()
        return admitted && !closed && revision == captured && token == item && (expected == nil || request == expected)
    }

    private func itemChanged(_ item: AVPlayerItem?) {
        guard !closed else { return }
        let captured = revision, token = token
        meter.detach(from: attached); attached = nil; audioLevels = nil
        guard let item, let token, current(token, revision: captured) else { return }
        meter.attach(to: item); attached = item
        guard current(token, revision: captured) else { return }
        native.feed.setEffects(effects, transfer: effects.transfer, sampleBus: samples)
    }

    public func close() {
        guard !closed else { return }
        closed = true; revision = UUID(); request = UUID(); token = nil; admission = nil; polling = false
        native.onItemChanged = nil
        meter.detach(from: attached ?? native.player.currentItem); attached = nil; meter.close()
        if activated { audio.close() }
        audioLevels = nil
    }
}
#endif
