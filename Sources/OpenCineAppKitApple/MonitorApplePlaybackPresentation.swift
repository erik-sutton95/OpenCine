#if os(iOS)
import Foundation
import Observation
import OpenCineAppKit
import OpenCineApple
import OpenCineMedia

/// One playback page's native runtime: each admitted item gets a fresh feed and native frame
/// source plus its assist session, and the previous assists close first. The camera source
/// supplies its feed, its frame source (the plain file owner unless it has its own), its item
/// model and its effects projection as values.
@MainActor @Observable public final class MonitorApplePlaybackPresentation<Payload: Sendable, Look: Sendable> {
    private struct Installation {
        let id: UUID
        let native: any MonitorPlaybackFrameSource
        let assists: MonitorPlaybackAssistSession
    }
    private enum Field: Equatable { case native, assists }
    @ObservationIgnored private var installation: Installation?
    @ObservationIgnored private var factoryRevision = UUID()
    @ObservationIgnored private var notifying = false
    @ObservationIgnored private var pendingNotifications: [Field] = []
    @ObservationIgnored private let makeFeed: @MainActor () -> MonitorPlaybackFeedSession
    @ObservationIgnored private let audioSession: MonitorPlaybackAudioSession
    @ObservationIgnored private let samples: @MainActor () -> LiveFrameSampleBus
    @ObservationIgnored private let onTapFailure: @Sendable (Int32) -> Void
    @ObservationIgnored private let onAudioFailure: @Sendable (String) -> Void
    @ObservationIgnored private let audioOwnership: (@MainActor @Sendable (Bool) -> Void)?
    /// The source's projection of the operator effects onto its feed (calibration values).
    @ObservationIgnored public let projectEffects: @MainActor (MonitorFrameEffects) -> MonitorFrameEffects

    /// The current item's frame source; the picture, backdrop and assists bind to it.
    public var native: (any MonitorPlaybackFrameSource)? {
        access(keyPath: \.native); return installation?.native
    }
    public var assists: MonitorPlaybackAssistSession? {
        access(keyPath: \.assists); return installation?.assists
    }

    /// `samples` is read when an item is admitted, so a host that swaps its bus is followed.
    /// `audioOwnership` hears when a page player claims and releases the audio session.
    public init(makeFeed: @escaping @MainActor () -> MonitorPlaybackFeedSession,
        audioSession: MonitorPlaybackAudioSession, samples: @escaping @MainActor () -> LiveFrameSampleBus,
        projectEffects: @escaping @MainActor (MonitorFrameEffects) -> MonitorFrameEffects = { $0 },
        onTapFailure: @escaping @Sendable (Int32) -> Void = { _ in },
        onAudioFailure: @escaping @Sendable (String) -> Void = { _ in },
        audioOwnership: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        self.makeFeed = makeFeed; self.audioSession = audioSession; self.samples = samples
        self.projectEffects = projectEffects
        self.onTapFailure = onTapFailure; self.onAudioFailure = onAudioFailure
        self.audioOwnership = audioOwnership
    }

    /// The page's item owner over `library` on the plain file owner; `makePlayback` builds the
    /// source's item model on the fresh native player.
    public func makeOwner(library: MonitorMediaLibraryModel<Payload>,
        recordAdmission: @escaping @MainActor (MonitorMediaRecord<Payload>) -> MonitorPlaybackAdmission,
        makePlayback: @escaping @MainActor (MonitorApplePlaybackOwner) -> MonitorMediaPlaybackModel<Payload, Look>
    ) -> MonitorOperatorMediaModel<Payload, Look> {
        makeOwner(library: library, recordAdmission: recordAdmission,
            makeNative: { MonitorApplePlaybackOwner(feed: $0) }, makePlayback: makePlayback)
    }

    /// The page's item owner over `library` on the source's own frame source. `makeNative`
    /// receives the page's fresh feed for the admitted item; the outgoing source is still
    /// `native` while it runs, so a source can join its predecessor's work.
    public func makeOwner<Native: MonitorPlaybackFrameSource>(library: MonitorMediaLibraryModel<Payload>,
        recordAdmission: @escaping @MainActor (MonitorMediaRecord<Payload>) -> MonitorPlaybackAdmission,
        makeNative: @escaping @MainActor (MonitorPlaybackFeedSession) -> Native,
        makePlayback: @escaping @MainActor (Native) -> MonitorMediaPlaybackModel<Payload, Look>
    ) -> MonitorOperatorMediaModel<Payload, Look> {
        MonitorOperatorMediaModel(library: library, recordAdmission: recordAdmission,
            makeAdmittedPlayback: { [self] _, admission in
                let revision = UUID()
                factoryRevision = revision
                installation?.assists.close()
                guard admission.isCurrent(), factoryRevision == revision else { return nil }
                let native = makeNative(makeFeed())
                let player = makePlayback(native)
                let assists = MonitorPlaybackAssistSession(audioSession: audioSession,
                    native: native, samples: samples(), projectEffects: projectEffects,
                    onTapFailure: onTapFailure, onAudioFailure: onAudioFailure,
                    audioOwnership: audioOwnership)
                guard admission.isCurrent(), factoryRevision == revision else {
                    assists.close(); player.close(); return nil
                }
                // One value commits both before a synchronous observer can reenter.
                installation = .init(id: revision, native: native, assists: assists)
                notify(.native)
                if installation?.id == revision, admission.isCurrent() { notify(.assists) }
                guard factoryRevision == revision, installation?.id == revision, admission.isCurrent() else {
                    assists.close(); player.close()
                    if installation?.id == revision {
                        installation = nil
                        notify(.native)
                        if installation == nil { notify(.assists) }
                    }
                    return nil
                }
                return player
            })
    }

    /// A successor commits synchronously while a notification waits for the outgoing one-shot
    /// observation callback to unregister; reentering a mutation would call it again. Queued
    /// fields are delivered in order once the outer notification returns.
    private func notify(_ field: Field) {
        if !pendingNotifications.contains(field) { pendingNotifications.append(field) }
        guard !notifying else { return }
        notifying = true
        defer { notifying = false }
        while !pendingNotifications.isEmpty {
            switch pendingNotifications.removeFirst() {
            case .native: withMutation(keyPath: \.native) {}
            case .assists: withMutation(keyPath: \.assists) {}
            }
        }
    }

    /// How far the native player has buffered `record`, while it is the page's current item.
    public func bufferedThroughSeconds(record: MonitorMediaRecord<Payload>,
        owner: MonitorOperatorMediaModel<Payload, Look>) -> Double? {
        owner.playback.flatMap { playback -> Double? in
            guard playback.ready, owner.presents(playback.token),
                playback.active?.asset.id == record.asset.id, let native = installation?.native,
                playback.native === native
            else { return nil }
            return native.bufferedThroughSeconds(token: playback.token)
        }
    }
}
#endif
