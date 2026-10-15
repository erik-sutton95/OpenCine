#if os(iOS)
import Foundation
import Observation
import OpenCineAppKit
import OpenCineApple
import OpenCineMedia

/// One playback page's native runtime: each admitted item gets a fresh feed and native player
/// plus its assist session, and the previous assists close first. The camera source supplies
/// its feed, its item model and its effects projection as values.
@MainActor @Observable public final class MonitorApplePlaybackPresentation<Payload: Sendable, Look: Sendable> {
    @ObservationIgnored private var currentNative: MonitorApplePlaybackOwner?
    @ObservationIgnored private var currentAssists: MonitorPlaybackAssistSession?
    @ObservationIgnored private let makeFeed: @MainActor () -> MonitorPlaybackFeedSession
    @ObservationIgnored private let audioSession: MonitorPlaybackAudioSession
    @ObservationIgnored private let samples: @MainActor () -> LiveFrameSampleBus
    @ObservationIgnored private let onTapFailure: @Sendable (Int32) -> Void
    @ObservationIgnored private let onAudioFailure: @Sendable (String) -> Void
    /// The source's projection of the operator effects onto its feed (calibration values).
    @ObservationIgnored public let projectEffects: @MainActor (MonitorFrameEffects) -> MonitorFrameEffects

    /// The current item's native owner; the picture, backdrop and assists bind to it.
    public var native: MonitorApplePlaybackOwner? {
        access(keyPath: \.native); return currentNative
    }
    public var assists: MonitorPlaybackAssistSession? {
        access(keyPath: \.assists); return currentAssists
    }

    /// `samples` is read when an item is admitted, so a host that swaps its bus is followed.
    public init(makeFeed: @escaping @MainActor () -> MonitorPlaybackFeedSession,
        audioSession: MonitorPlaybackAudioSession, samples: @escaping @MainActor () -> LiveFrameSampleBus,
        projectEffects: @escaping @MainActor (MonitorFrameEffects) -> MonitorFrameEffects = { $0 },
        onTapFailure: @escaping @Sendable (Int32) -> Void = { _ in },
        onAudioFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.makeFeed = makeFeed; self.audioSession = audioSession; self.samples = samples
        self.projectEffects = projectEffects
        self.onTapFailure = onTapFailure; self.onAudioFailure = onAudioFailure
    }

    /// The page's item owner over `library`; `makePlayback` builds the source's item model on
    /// the fresh native player.
    public func makeOwner(library: MonitorMediaLibraryModel<Payload>,
        recordAdmission: @escaping @MainActor (MonitorMediaRecord<Payload>) -> MonitorPlaybackAdmission,
        makePlayback: @escaping @MainActor (MonitorApplePlaybackOwner) -> MonitorMediaPlaybackModel<Payload, Look>
    ) -> MonitorOperatorMediaModel<Payload, Look> {
        MonitorOperatorMediaModel(library: library, recordAdmission: recordAdmission,
            makeAdmittedPlayback: { [self] _, admission in
                currentAssists?.close()
                guard admission.isCurrent() else { return nil }
                let native = MonitorApplePlaybackOwner(feed: makeFeed())
                let player = makePlayback(native)
                let assists = MonitorPlaybackAssistSession(audioSession: audioSession,
                    native: native, samples: samples(), projectEffects: projectEffects,
                    onTapFailure: onTapFailure, onAudioFailure: onAudioFailure)
                guard admission.isCurrent() else { assists.close(); player.close(); return nil }
                currentNative = native; currentAssists = assists
                withMutation(keyPath: \.native) {}; withMutation(keyPath: \.assists) {}
                guard admission.isCurrent() else { assists.close(); player.close(); return nil }
                return player
            })
    }

    /// How far the native player has buffered `record`, while it is the page's current item.
    public func bufferedThroughSeconds(record: MonitorMediaRecord<Payload>,
        owner: MonitorOperatorMediaModel<Payload, Look>) -> Double? {
        owner.playback.flatMap { playback -> Double? in
            guard playback.ready, owner.isCurrent(playback.token),
                playback.active?.asset.id == record.asset.id, playback.native === currentNative
            else { return nil }
            return currentNative?.bufferedThroughSeconds(token: playback.token)
        }
    }
}
#endif
