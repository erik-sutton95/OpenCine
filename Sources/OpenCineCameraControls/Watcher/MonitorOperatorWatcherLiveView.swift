#if os(iOS)
    import MetalKit
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineAppKitApple
    import OpenCineApple
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI

    /// The live decoder facts the operator screens read besides the shared picture.
    @MainActor
    public protocol MonitorOperatorLiveDecoder: MonitorLiveVideoSource {
        /// The source's color mode; it sets the incoming transfer.
        var incomingColorMode: ColorMode? { get set }
        /// The assist stack the backdrop renders with the presented picture.
        var backdropEffects: MonitorFrameEffects { get }
    }

    /// The app model behind the live operator screens: its picture, assists, scopes and the
    /// views that stay with the app (inspector preview and LUT menu).
    @MainActor
    public protocol MonitorLiveOperatorHost: LiveChromeHost, AnyObject, Observable {
        associatedtype Picture: MonitorLivePictureApp where Picture.Decoder: MonitorOperatorLiveDecoder
        associatedtype InspectorPreview: View
        associatedtype LookMenu: View

        var assist: MonitorAssistState<MonitorLUTLooks> { get }
        var liveBackdrop: OpenCineAppKitApple.MonitorVideoBackdropRenderer { get }
        var monitorSamples: LiveFrameSampleBus { get }
        var monitorTransfer: MonitorTransfer? { get }
        var monitorColorMode: ColorMode? { get }
        var hdrDisplayActive: Bool { get }
        var isWatchingFeed: Bool { get }
        var recordConfirmationEnabled: Bool { get }

        static var assistStores: AssistPanelStores { get }
        static var falseColorLooks: FalseColorLooks { get }
        static var operatorHaptics: OperatorHaptics { get }

        @ViewBuilder func inspectorPreview(tool: MonitorAssistSelection) -> InspectorPreview
        @ViewBuilder func lookMenu() -> LookMenu
    }

    extension MonitorLivePictureApp {
        /// Scopes present with the app's HDR panel.
        public static func scopeDisplay(_ view: MTKView) -> MonitorScopeDisplayOptions {
            hdrDisplay.configure(view)
            return MonitorScopeDisplayOptions(hdr: hdrDisplay.isEnabled, gain: hdrDisplay.presentGain)
        }
    }

    extension MonitorLiveOperatorHost {
        /// The assist tools over the monitored source (own camera or watched feed).
        public var liveAssistSource: MonitorOperatorLiveAssistSource {
            MonitorOperatorLiveAssistSource(
                stores: Self.assistStores, looks: Self.falseColorLooks, haptics: Self.operatorHaptics,
                readBundle: { self.monitorSamples.displayBundle },
                readTransfer: {
                    self.monitorTransfer ?? self.monitorColorMode.map(MonitorTransfer.init) ?? .rec709
                },
                readClipByte: { self.monitorSamples.exposureCeiling.clipByte(transfer: $0) },
                configureDisplay: { Picture.scopeDisplay($0) })
        }
    }

    extension MonitorWatcherSource {
        public var colorMode: ColorMode? { ColorMode(label: state.color) }
        public var transfer: MonitorTransfer? { colorMode.map(MonitorTransfer.init) }
    }

    /// What differs between apps on the watcher screen, as typed values.
    public struct MonitorWatcherLiveBrand: Sendable {
        /// The zoom label's ceiling for the relayed zoom choices; `nil` keeps the vocabulary default.
        public var zoomLabelCeiling: @Sendable (_ zoomHundredths: [Int]) -> Double?

        public init(
            zoomLabelCeiling: @escaping @Sendable (_ zoomHundredths: [Int]) -> Double? = { _ in nil }
        ) {
            self.zoomLabelCeiling = zoomLabelCeiling
        }
    }

    @MainActor
    public protocol MonitorWatcherLiveHost: MonitorLiveOperatorHost, WatcherRelayViewer
    where WatcherDecoder == Picture.Decoder {
        static var watcherBrand: MonitorWatcherLiveBrand { get }
        var watcherCameraFamily: CameraBodyFamily { get }
        var watcherLookProfile: CameraLUTProfile? { get }
    }

    /// Monitor tools around a remote source. Never opens a camera session.
    public struct MonitorOperatorWatcherLiveView<Host: MonitorWatcherLiveHost>: View {
        @Environment(Host.self) private var model
        @State private var pictureGeometry: MonitorWatcherPictureGeometry?
        private var client: MonitorWatcherSource<Host.Picture.Decoder> { model.relayClient }
        private var mirrored: Bool {
            GimbalStick.liveViewFlip(
                poseViewFlip: client.decoder.poseViewFlip,
                assistMirror: model.assist.mirrorsHorizontally)
        }

        public init() {}

        public var body: some View {
            MonitorOperatorWatcherScreen(host: model, value: watcherValue,
                pictureSize: client.decoder.pictureSize, mirrored: mirrored,
                confirmRecording: model.recordConfirmationEnabled, assists: model.liveAssistSource,
                action: handleWatcherAction, readTapSource: { client.tapSource },
                capturedTapAction: { size in
                    Self.capturedTapAction(client: client, feed: size,
                        mirrored: { mirrored }, flippedVertically: { model.assist.flipsVertically })
                }, onGeometry: { pictureGeometry = $0 }) { effects in
                    MonitorLiveVideoView<Host.Picture>(decoder: client.decoder, effects: effects, sampleBus: client.samples,
                        transfer: client.transfer, pictureFlip: client.decoder.poseViewFlip,
                        hdrDisplay: model.hdrDisplayActive)
                } preview: { model.inspectorPreview(tool: $0)
                } lookMenu: { model.lookMenu() }
                .monitorVideoBackdrop(renderer: model.liveBackdrop,
                    configuration: backdropConfiguration,
                    enabled: model.isWatchingFeed && !model.assist.gradesClip && pictureGeometry?.belongs(to: client.tapSource) == true,
                    surroundRGB: 0x000000) { _ in backdropSources() }
                .onAppear { syncColor() }
                .onChange(of: client.state.color) { _, _ in syncColor() }
                .onChange(of: client.state.cameraModel) { _, _ in syncColor() }
        }

        private var backdropConfiguration: [MonitorVideoBackdropConfiguration] {
            guard let geometry = pictureGeometry, geometry.belongs(to: client.tapSource) else { return [] }
            let feed = geometry.feed
            return [MonitorVideoBackdropConfiguration(source: ObjectIdentifier(client.decoder),
                generation: Int(client.samples.inspectorSourceEpoch), effects: model.assist.effects,
                geometry: [CGFloat(feed.x), CGFloat(feed.y), CGFloat(feed.width), CGFloat(feed.height), geometry.mirrored ? 1 : 0])]
        }
        private func backdropSources() -> [MonitorVideoBackdropSource] {
            guard let geometry = pictureGeometry, geometry.belongs(to: client.tapSource) else { return [] }
            let feed = CGRect(x: CGFloat(geometry.feed.x), y: CGFloat(geometry.feed.y),
                width: CGFloat(geometry.feed.width), height: CGFloat(geometry.feed.height))
            let decoder = client.decoder, samples = client.samples
            let epoch = samples.inspectorSourceEpoch
            guard let token = decoder.sourceToken, let buffer = decoder.backdropSource else { return [] }
            let effects = decoder.backdropEffects
            return [MonitorVideoBackdropSource(buffer: buffer, effects: effects,
                frame: MonitorVideoBackdropSource.displayedFrame(sourceAspect: decoder.pictureAspect, effects: effects, in: feed),
                clip: feed, identity: .live(token: token, epoch: epoch), admission: { [weak decoder, weak samples] in
                    guard let decoder, let samples else { return false }
                    return decoder.sourceToken == token && samples.inspectorSourceEpoch == epoch
                })]
        }

        public static func capturedTapAction(client: MonitorWatcherSource<Host.Picture.Decoder>, feed: CGSize,
            mirrored: @escaping @MainActor () -> Bool, flippedVertically: @escaping @MainActor () -> Bool
        ) -> @MainActor (CGPoint) -> MonitorWatcherFocus? {
            let captured = client.tapSource
            return { location in
                guard captured.admits(client.tapSource) else { return nil }
                let mirror = mirrored(), flip = flippedVertically()
                guard captured.admits(client.tapSource) else { return nil }
                return client.sendTapFocus(x: Double(location.x), y: Double(location.y),
                    width: Double(feed.width), height: Double(feed.height),
                    mirrored: mirror, flippedVertically: flip, captured: captured)
            }
        }

        /// The relayed zoom choices' labels, with this app's label ceiling.
        public static func zoomChoiceTitles(_ zoomHundredths: [Int]) -> [String] {
            let ceiling = Host.watcherBrand.zoomLabelCeiling(zoomHundredths)
            return zoomHundredths.map { raw in
                let factor = Double(raw) / 100
                return ceiling.map { CamFov.displayLabel(factor: factor, ceiling: $0) }
                    ?? CamFov.displayLabel(factor: factor)
            }
        }

        private func syncColor() {
            client.decoder.incomingColorMode = client.colorMode
            model.assist.syncLUT(
                to: client.colorMode, family: model.watcherCameraFamily,
                cameraName: client.state.cameraModel, lookProfile: model.watcherLookProfile,
                persistLast: false)
        }

        private var watcherValue: MonitorWatcherPresentation {
            let context = MonitorWatcherContext(source: String(describing: ObjectIdentifier(client)),
                revision: client.actionRevision, canControl: client.canControl, recording: client.state.isRecording)
            var settings: [MonitorWatcherSettingValue] = []
            if let options = client.state.controlOptions {
                let iso = options.isoIndices.compactMap { raw -> MonitorWatcherChoice? in
                    IsoIndex(rawValue: UInt8(clamping: raw)).map { MonitorWatcherChoice(id: raw, title: $0.label) }
                }
                if !iso.isEmpty { settings.append(.init(id: .iso, title: "ISO \(client.state.iso)", choices: iso)) }
                if !options.shutterDenominators.isEmpty {
                    settings.append(.init(id: .shutter, title: client.state.shutter.isEmpty ? "Shutter" : client.state.shutter,
                        choices: options.shutterDenominators.map { .init(id: $0, title: "1/\($0)") }))
                }
                if !options.zoomHundredths.isEmpty {
                    settings.append(.init(id: .zoom, title: client.state.zoom.isEmpty ? "Zoom" : client.state.zoom,
                        choices: zip(options.zoomHundredths, Self.zoomChoiceTitles(options.zoomHundredths)).map {
                            .init(id: $0, title: $1)
                        }))
                }
            }
            let notice: MonitorWatcherNotice?
            switch model.watcherJoinStatus {
            case .reconnecting(let attempt, let maximum): notice = MonitorWatcherNotices.reconnecting(attempt: attempt, maximum: maximum)
            case .failed(let message): notice = MonitorWatcherNotices.failed(message)
            case .live: notice = client.waitingForPicture ? MonitorWatcherNotices.waitingForPicture : nil
            default: notice = MonitorWatcherNotices.joining
            }
            return MonitorWatcherPresentation(context: context, hostTitle: client.hostTitle, receivedFPS: client.receivedFPS,
                readings: [.init("FORMAT", value: client.state.format), .init("COLOR", value: client.state.color),
                    .init("SHUTTER", value: client.state.shutter), .init("ISO", value: client.state.iso),
                    .init("ZOOM", value: client.state.zoom),
                    .init("BATTERY", value: MonitorOperatorPowerReading.readoutLabel(client.state.batteryReading))],
                settings: settings, holderName: client.token.holderName,
                canRequestControl: model.watcherJoinStatus == .live && client.state.allowsControlRequests,
                controlRequested: client.controlRequested, notice: notice)
        }

        private func handleWatcherAction(_ action: MonitorWatcherAction) {
            guard watcherValue.admits(action) else { return }
            switch action {
            case .leave: model.stopWatching()
            case .chooseFeed: model.stopWatching(); model.openWatcherBrowse()
            case .requestControl: client.requestControl()
            case .releaseControl: client.releaseControl()
            case .record: client.toggleRecording()
            case .set(_, let setting, let choice):
                switch setting {
                case .iso: client.setISO(choice)
                case .shutter: client.setShutterDenominator(choice)
                case .zoom: client.setZoom(choice)
                }
            }
        }
    }
#endif
