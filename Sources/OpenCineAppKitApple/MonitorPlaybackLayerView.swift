#if os(iOS)
import AVFoundation
import OpenCineApple
import OpenCineMedia
import SwiftUI

/// The stable native playback picture every app mounts: one feed host bound to the page's feed
/// session and player. UI chrome is a sibling of this view. The app supplies its picture host
/// (renderer and HDR layer configuration) as a value.
public struct MonitorPlaybackLayerView: UIViewRepresentable {
    let player: AVPlayer
    let session: MonitorPlaybackFeedSession
    let makeHost: @MainActor () -> MonitorPlaybackFeedHost
    let qualificationItemToken: (@MainActor () -> MonitorPlaybackItemToken?)?
    /// Effects as the feed applies them (the source's projection already applied).
    let effects: MonitorFrameEffects
    let transfer: MonitorTransfer
    let sampleBus: LiveFrameSampleBus

    public init(player: AVPlayer, session: MonitorPlaybackFeedSession,
        makeHost: @escaping @MainActor () -> MonitorPlaybackFeedHost,
        qualificationItemToken: (@MainActor () -> MonitorPlaybackItemToken?)? = nil,
        effects: MonitorFrameEffects, transfer: MonitorTransfer, sampleBus: LiveFrameSampleBus) {
        self.player = player; self.session = session; self.makeHost = makeHost
        self.qualificationItemToken = qualificationItemToken
        self.effects = effects; self.transfer = transfer; self.sampleBus = sampleBus
    }

    @MainActor public final class Coordinator {
        let session: MonitorPlaybackFeedSession
        let generation: Int
        weak var qualificationProbe: MonitorNativeQualificationProbe?
        init(session: MonitorPlaybackFeedSession) {
            self.session = session
            self.generation = session.reserveHostGeneration()
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    public func makeUIView(context: Context) -> MonitorPlaybackFeedHost {
        let view = makeHost()
        view.accessibilityIdentifier = "monitor.native.picture"
        let qualificationItemToken = qualificationItemToken
        context.coordinator.qualificationProbe = MonitorNativeQualificationProbe.install(in: view) { [weak view, weak session, weak player] in
            guard let view, let session, let player, session.debugBoundHost === view else { return nil }
            return .playback(player: player, layer: view.playerLayer,
                             sourcePresented: session.debugItemHasPresented,
                             itemToken: qualificationItemToken?())
        }
        view.attachGeneration = context.coordinator.generation
        session.attach(host: view, player: player)
        session.setEffects(effects, transfer: transfer, sampleBus: sampleBus)
        return view
    }

    public func updateUIView(_ uiView: MonitorPlaybackFeedHost, context: Context) {
        let qualificationItemToken = qualificationItemToken
        context.coordinator.qualificationProbe?.snapshot = { [weak uiView, weak session, weak player] in
            guard let uiView, let session, let player, session.debugBoundHost === uiView else { return nil }
            return .playback(player: player, layer: uiView.playerLayer,
                             sourcePresented: session.debugItemHasPresented,
                             itemToken: qualificationItemToken?())
        }
        uiView.attachGeneration = context.coordinator.generation
        session.attach(host: uiView, player: player)
        session.setEffects(effects, transfer: transfer, sampleBus: sampleBus)
    }

    public static func dismantleUIView(_ uiView: MonitorPlaybackFeedHost, coordinator: Coordinator) {
        coordinator.qualificationProbe?.snapshot = { nil }
        coordinator.qualificationProbe?.removeFromSuperview()
        coordinator.session.detach(host: uiView)
        uiView.playerLayer.player = nil
    }
}
#endif
