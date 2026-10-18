#if os(iOS)
    import AVFoundation
    import OpenCineApple
    import OpenCineMedia
    import SwiftUI
    import UIKit

    /// The app's live decoder as the shared live picture drives it. The retained decoder,
    /// demand and presentation live in ``MonitorLiveVideoRuntime``; the app adds the operator
    /// effects it observes, how a sample bus becomes its source publication, and the simulator
    /// footage it substitutes for a camera.
    @MainActor
    public protocol MonitorLiveVideoSource: MonitorLiveVideoRuntime {
        var effects: MonitorFrameEffects { get set }
        func bindSourcePublication(_ bus: LiveFrameSampleBus)
        func startSimulatorSampleIfNeeded()
    }

    /// The typed values one app supplies to its live picture: the decoder type, the app's HDR
    /// panel and feed-upscaler preference, its log subsystem and an optional present observer.
    @MainActor
    public protocol MonitorLivePictureApp {
        associatedtype Decoder: MonitorLiveVideoSource
        /// Each app's one `LiveHDRDisplay.app`.
        static var hdrDisplay: LiveHDRDisplay { get }
        /// Each app's persisted feed-upscaler choice.
        static var feedUpscaler: MonitorUpscalerPreference { get }
        static var logSubsystem: String { get }
        /// Called after each successful Metal present; `nil` when the app does not observe them.
        static var presentObserver: (() -> Void)? { get }
    }

    extension MonitorLivePictureApp {
        /// Read by the feed on every present: the app's upscaler choice and HDR panel state.
        public static func presentationOptions(screen: UIScreen?) -> MonitorPresentationOptions {
            hdrDisplay.refreshGain(screen: screen)
            return MonitorPresentationOptions(
                upscaler: feedUpscaler.upscaler,
                hdr: hdrDisplay.isEnabled, hdrGain: hdrDisplay.presentGain,
                previewSuperResolutionInput: feedUpscaler.presentsSuperResolutionInput)
        }
    }

    /// The Core Image feed (used only while GPU assists are on), presenting with the app's
    /// upscaler and HDR panel state.
    public final class MonitorLiveFeedView<App: MonitorLivePictureApp>: MonitorPictureHost {
        public init(frame: CGRect = .zero) {
            super.init(
                frame: frame, options: { App.presentationOptions(screen: $0) },
                logSubsystem: App.logSubsystem)
            onSuccessfulPresent = App.presentObserver
        }
        public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    /// Hosts the HEVC display layer and the app's Core Image feed.
    public final class MonitorLiveDisplayLayerView<App: MonitorLivePictureApp>: MonitorVideoPictureContainer {
        public let ciFeed: MonitorLiveFeedView<App>
        public var qualificationProbe: MonitorNativeQualificationProbe?
        public init(_ layer: AVSampleBufferDisplayLayer) {
            let feed = MonitorLiveFeedView<App>()
            self.ciFeed = feed
            super.init(layer, processedPicture: feed)
        }
        public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        public func applyHDRDisplay(_ enabled: Bool) {
            App.hdrDisplay.setEnabled(enabled, screen: window?.screen)
            App.hdrDisplay.configure(displayLayer, screen: window?.screen)
            ciFeed.syncHDRDisplay()
        }
    }

    /// The live picture. `effects` and `sampleBus` are read here so toggling PEAK/LUT/WAVE
    /// refreshes this representable and pushes the current stack and bus into the decoder; the
    /// live screen body otherwise never observes those flags.
    ///
    /// Mirror is a negative-X transform on a host view
    /// that wraps both renderers. Applied at present time (not SwiftUI `scaleEffect`) so
    /// MIRROR assist lands with the presented picture. MIRROR Vertical is a negative Y on the
    /// same host; it has no pose latch, so it applies on the toggle.
    public struct MonitorLiveVideoView<App: MonitorLivePictureApp>: View {
        public let decoder: App.Decoder
        public var effects: MonitorFrameEffects
        public var sampleBus: LiveFrameSampleBus
        /// The camera's monitor transfer; the simulator clip is `.dlog2`.
        public var transfer: MonitorTransfer?
        /// MIRROR assist. Applied on the host view so reconnect cannot skip it.
        public var pictureFlip: Bool
        /// Outdoor HDR panel. Identity presents through Metal EDR.
        public var hdrDisplay: Bool
        public var qualification: (@MainActor () -> MonitorNativeQualificationSnapshot?)?

        public init(
            decoder: App.Decoder, effects: MonitorFrameEffects, sampleBus: LiveFrameSampleBus,
            transfer: MonitorTransfer? = nil, pictureFlip: Bool = false, hdrDisplay: Bool = false,
            qualification: (@MainActor () -> MonitorNativeQualificationSnapshot?)? = nil
        ) {
            self.decoder = decoder
            self.effects = effects
            self.sampleBus = sampleBus
            self.transfer = transfer
            self.pictureFlip = pictureFlip
            self.hdrDisplay = hdrDisplay
            self.qualification = qualification
        }

        public var body: some View {
            MonitorLiveVideoRepresentable<App>(
                decoder: decoder,
                effects: rasterEffects,
                assistMirror: effects.mirror,
                flipVertical: effects.mirrorVertical,
                pictureFlip: pictureFlip,
                sampleBus: sampleBus,
                transfer: transfer,
                feedUpscaler: App.feedUpscaler.upscaler,
                hdrDisplay: hdrDisplay,
                qualification: qualification
            )
            .transaction { $0.animation = nil }
        }

        /// Mirror stays a view-space flip so the GPU path does not also flip the buffer.
        private var rasterEffects: MonitorFrameEffects {
            var fx = effects
            fx.mirror = false
            return fx
        }
    }

    public struct MonitorLiveVideoRepresentable<App: MonitorLivePictureApp>: UIViewRepresentable {
        public let decoder: App.Decoder
        public var effects: MonitorFrameEffects
        public var assistMirror: Bool
        public var flipVertical: Bool
        public var pictureFlip: Bool
        public var sampleBus: LiveFrameSampleBus
        public var transfer: MonitorTransfer?
        public var feedUpscaler: MonitorUpscaler
        public var hdrDisplay: Bool
        public var qualification: (@MainActor () -> MonitorNativeQualificationSnapshot?)?

        public init(
            decoder: App.Decoder, effects: MonitorFrameEffects, assistMirror: Bool,
            flipVertical: Bool = false, pictureFlip: Bool, sampleBus: LiveFrameSampleBus,
            transfer: MonitorTransfer?, feedUpscaler: MonitorUpscaler, hdrDisplay: Bool,
            qualification: (@MainActor () -> MonitorNativeQualificationSnapshot?)? = nil
        ) {
            self.decoder = decoder
            self.effects = effects
            self.assistMirror = assistMirror
            self.flipVertical = flipVertical
            self.pictureFlip = pictureFlip
            self.sampleBus = sampleBus
            self.transfer = transfer
            self.feedUpscaler = feedUpscaler
            self.hdrDisplay = hdrDisplay
            self.qualification = qualification
        }

        public func makeUIView(context: Context) -> MonitorLiveDisplayLayerView<App> {
            let view = MonitorLiveDisplayLayerView<App>(decoder.displayLayer)
            view.accessibilityIdentifier = "monitor.native.picture"
            if let qualification {
                view.qualificationProbe = MonitorNativeQualificationProbe.install(in: view) { [weak view] in
                    guard view?.ownsDisplayLayer == true else { return nil }
                    return qualification()
                }
            }
            view.onReady = { [decoder] in decoder.noteDisplayReady() }
            decoder.processedFeed = view.ciFeed
            view.applyHDRDisplay(hdrDisplay)
            bindMirror(decoder, view: view)
            wire(decoder)
            return view
        }

        public func updateUIView(_ uiView: MonitorLiveDisplayLayerView<App>, context: Context) {
            updateDisplay(uiView)
        }

        public func updateDisplay(_ uiView: MonitorLiveDisplayLayerView<App>) {
            guard uiView.ownsDisplayLayer else { return }
            if let qualification {
                uiView.qualificationProbe?.snapshot = { [weak uiView] in
                    guard uiView?.ownsDisplayLayer == true else { return nil }
                    return qualification()
                }
            }
            uiView.onReady = { [decoder] in decoder.noteDisplayReady() }
            decoder.processedFeed = uiView.ciFeed
            uiView.applyHDRDisplay(hdrDisplay)
            bindMirror(decoder, view: uiView)
            guard
                decoder.sampleBus !== sampleBus
                    || decoder.effects != effects
                    || decoder.feedUpscaler != feedUpscaler
                    || decoder.hdrDisplayEnabled != hdrDisplay
                    || decoder.assistMirror != assistMirror
                    || (transfer != nil && decoder.incomingTransfer != transfer)
            else { return }
            wire(decoder)
        }

        private func bindMirror(_ decoder: App.Decoder, view: MonitorLiveDisplayLayerView<App>) {
            decoder.applyPictureMirror = { [weak view] mirrored in
                view?.setPictureMirrored(mirrored)
            }
            decoder.assistMirror = assistMirror
            view.setPictureFlippedVertically(flipVertical)
        }

        private func wire(_ decoder: App.Decoder) {
            decoder.bindSourcePublication(sampleBus)
            decoder.effects = effects
            decoder.feedUpscaler = feedUpscaler
            decoder.hdrDisplayEnabled = hdrDisplay
            decoder.adoptIncomingTransfer(transfer)
            decoder.startSimulatorSampleIfNeeded()
        }
    }
#endif
