#if os(iOS)
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineAppKitApple
    import OpenCineApple
    import OpenCineCameraVocabulary
    import OpenCineCore
    import OpenCineMedia
    import OpenCineMotion
    import SwiftUI

    /// The live decoder as the live screen binds it to the app's sample bus and effects.
    @MainActor
    public protocol MonitorOperatorLiveScreenDecoder: MonitorOperatorLiveDecoder {
        func attach(
            sampleBus: LiveFrameSampleBus, effects provider: @escaping () -> MonitorFrameEffects,
            transfer: @escaping () -> MonitorTransfer?)
        func stopSimulatorSample()
    }

    /// The camera session facts and actions the live screen reads.
    @MainActor
    public protocol MonitorLiveScreenSession: AnyObject, Observable {
        associatedtype Decoder: MonitorOperatorLiveScreenDecoder
        var decoder: Decoder { get }
        var status: CameraStatus { get set }
        var cameraGalleryOpen: Bool { get }
        var incidentSettingsCovered: Bool { get set }
        func recordFeedBreadcrumb(_ kind: FeedIncidentBreadcrumbKind, detail: String)
        var gimbalLimitPulse: UInt { get }
        var gimbalLimitContact: GimbalLimitWatch.Contact { get }
        var gimbalLimitPanSign: Double { get }
        var gimbalLimitTiltSign: Double { get }
        var isLocked: Bool { get set }
        var pictureAspect: CGFloat { get }
        var isFeedWarming: Bool { get }
        var isVerticalPicture: Bool { get }
        var feedRecovering: Bool { get }
        var controlBusy: Bool { get }
        var controlNote: String? { get set }
        var sessionRecovery: SessionRecoveryState { get }
        var zoomMax: Double { get }
        var zoomStops: [Double] { get }
        var zoomDialReadout: Double { get }
        var zoomOptimistic: Double? { get }
        var zoomStop: Double { get }
        var focusPoint: CGPoint { get }
        var focusOverlay: FocusOverlay { get }
        var dimmedFaces: [TrackingBox] { get }
        var isFocusResetAvailable: Bool { get }
        var supportsTapFocus: Bool { get }
        var isTracking: Bool { get }
        var searchBox: TrackingBox? { get }
        var subjectBox: TrackingBox? { get }
        func cancelSubjectTracking()
        var wantsFaceAF: Bool { get }
        var nativeQualificationSnapshot: MonitorNativeQualificationSnapshot { get }
        /// The gimbal's level reading.
        var liveLevelReading: LevelReading { get }
        /// Stops a programmed gimbal move (the lock blocks input).
        func cancelProgrammedGimbalMove()
        /// The photo shutter.
        func takeLivePhoto()
    }

    /// The app model behind the live screen, with the values that stay the app's.
    @MainActor
    public protocol MonitorLiveScreenHost: MonitorLiveOperatorHost, GimbalPanelHost, GimbalStickHost,
        GimbalGamepadHost, HeadTrackHost
    where Session.Decoder == Picture.Decoder {
        associatedtype Session: MonitorLiveScreenSession
        associatedtype LUTSheet: View
        var session: Session { get }
        var shell: ShellModel { get }
        var frameSamples: LiveFrameSampleBus { get }
        var portraitFeedAspect: PortraitFeedAspect { get set }
        var virtualJoystickSize: MonitorJoystickSize { get }
        func syncLiveMonitorColor()
        /// The app's headphone motion bridge.
        static func headphoneBridge() -> HeadphoneMotionBridge
        /// The capabilities this camera body offers the live screen.
        var liveCapabilities: MonitorLayoutCapabilities { get }
        var liveZoomCaption: String { get }
        /// The color mode the simulator feed presents with, or `nil` to leave the session's.
        var simulatorLiveColorMode: ColorMode? { get }
        func liveLevelDisplay(_ mode: LevelReading.Mode) -> MonitorLevelDisplay
        /// The picture exposure readout, when the app meters one.
        var livePictureEV: (() -> EvComp?)? { get }
        @ViewBuilder func lutPicker() -> LUTSheet
    }

    /// The complete live operator screen over the app's camera session and native picture.
    public struct MonitorOperatorLiveScreen<Host: MonitorLiveScreenHost>: View {
        @Environment(Host.self) private var model
        @Environment(\.monitorWindowGeometry) private var windowGeometry
        @State private var interaction = MonitorOperatorInteraction()
        @State private var gamepad = GimbalGamepadBridge<Host>()
        @State private var headphones = Host.headphoneBridge()
        @State private var orientationObserver = InterfaceOrientationObserver()
        private var interfaceLocked: Bool { model.operatorSession.locked }
        private var showsBottomBars: Bool {
            model.chromeSectionMounts(.toolBar) || model.chromeSectionMounts(.cameraValues)
        }

        public init() {}

        public var body: some View {
            nativeSurface
            .monitorOperatorInteraction(host: model, interaction: interaction,
                covered: model.shell.cover != nil, motion: Bindable(model).liveGimbalPanel,
                orientation: orientationObserver.orientation, onInputAdmission: updateInputAdmission)
            // The camera body's own gallery opens Media, and leaving it closes Media.
            .onChange(of: model.session.cameraGalleryOpen) { _, open in
                model.shell.followCameraGallery(open: open)
            }
            .onChange(of: model.shell.cover) { oldPanel, panel in
                model.session.incidentSettingsCovered = panel == .settings
                if oldPanel == .settings { model.session.recordFeedBreadcrumb(.settingsExit, detail: "") }
                if panel == .settings { model.session.recordFeedBreadcrumb(.settingsEnter, detail: "") }
            }
            .onChange(of: model.headTrackingEnabled) { _, _ in
                headphones.sync()
            }
            .onChange(of: model.session.gimbalLimitPulse) { _, _ in
                gamepad.pulseLimit(
                    model.session.gimbalLimitContact,
                    panSign: model.session.gimbalLimitPanSign,
                    tiltSign: model.session.gimbalLimitTiltSign,
                    enabled: model.hapticsEnabled)
            }
            .sheet(isPresented: Bindable(model.assist).showLUTPicker) { model.lutPicker() }
        }

        private func updateInputAdmission(_ admission: MonitorInputAdmission) {
            model.session.isLocked = interfaceLocked
            switch admission {
            case .blocked(let reason):
                gamepad.noteBlocked(); headphones.noteBlocked()
                if reason == .lock { model.session.cancelProgrammedGimbalMove() }
            case .resumed: headphones.sync()
            }
        }

        private var nativeSurface: some View {
            GeometryReader { proxy in
                let safeArea = OperatorPanelMetrics.resolvedDeviceSafeArea(
                    proxy.safeAreaInsets, window: windowGeometry.safeArea)
                let size = LiveMonitorLayout.canvasSize(layoutSize: proxy.size, safeArea: safeArea, screenSize: windowGeometry.validSize)
                let layout = LiveMonitorLayout.fieldMonitor(size: size, safeArea: safeArea,
                    sourceAspect: model.session.pictureAspect,
                    fill: model.portraitFeedAspect == .fill && !model.assist.isVisible(.desqueeze),
                    showsValues: model.chromeSectionMounts(.cameraValues), showsBottomBars: showsBottomBars,
                    topControlInset: windowGeometry.topControlInset, joystick: model.virtualJoystickSize,
                    valueCount: MonitorOperatorCaptureInputs<CaptureSheet, MonitorDisplayChrome.Section,
                        MonitorOperatorLegacyCaptureIdentity>.captureSheetHost(model).valueCount)
                Color.clear.ignoresSafeArea().overlay(alignment: .topLeading) {
                    canvas(layout).frame(width: layout.viewport.width, height: layout.viewport.height, alignment: .topLeading)
                }
            }.ignoresSafeArea().preferredColorScheme(.dark).environment(\.colorScheme, .dark)
                .animation(.easeInOut(duration: 0.22), value: orientationObserver.orientation)
                .animation(.easeInOut(duration: 0.18), value: model.assist.clean)
                .animation(.easeOut(duration: 0.16), value: model.chromeEditorMode)
                .animation(.easeOut(duration: 0.22), value: model.session.isFeedWarming)
            .onAppear {
                let app = model
                orientationObserver.start()
                model.session.decoder.attach(
                    sampleBus: app.frameSamples,
                    effects: { [weak app] in
                        guard let app else { return MonitorFrameEffects() }
                        return app.assist.effects.withFaceAF(app.session.wantsFaceAF)
                    },
                    transfer: { [weak app] in
                        guard let app else { return nil }
                        return LiveMonitorColorScience.transfer(
                            isPhoto: app.session.status.isPhoto,
                            colorMode: app.session.status.colorMode)
                    }
                )
                #if targetEnvironment(simulator)
                    if let colorMode = model.simulatorLiveColorMode { model.session.status.colorMode = colorMode }
                #endif
                model.syncLiveMonitorColor()
                model.session.decoder.startSimulatorSampleIfNeeded()
                model.session.isLocked = interfaceLocked
                gamepad.attach(model: model)
                headphones.attach(host: model)
            }
            .onDisappear {
                orientationObserver.stop()
                headphones.detach()
                gamepad.detach()
                model.session.decoder.stopSimulatorSample()
            }
        }

        private func canvas(_ layout: LiveMonitorLayout) -> some View {
            let capability = model.liveCapabilities
            return MonitorOperatorLiveSurface(host: model, layout: layout, interaction: interaction,
                source: MonitorOperatorLivePresentation(pictureAspect: model.session.pictureAspect,
                    pictureWaiting: model.session.isFeedWarming, verticalPicture: model.session.isVerticalPicture,
                    recovering: model.session.feedRecovering, zoom: capability.zoom, gimbal: capability.gimbal,
                    headTracking: capability.headTracking, watching: model.isWatchingFeed),
                capture: MonitorOperatorLiveCaptureSource(confirmRecording: model.recordConfirmationEnabled,
                    busy: { model.session.controlBusy }, takePhoto: { model.session.takeLivePhoto() }),
                zoom: zoomSource, focus: focusSource, assists: model.liveAssistSource,
                portraitAspect: Bindable(model).portraitFeedAspect, orientation: orientationObserver.orientation,
                controlNote: Bindable(model.session).controlNote,
                headTracking: MonitorOperatorHeadTrackingSource(enabled: model.headTrackingEnabled,
                    title: model.headTrackControlTitle, readPose: { model.headTrackAxisPose },
                    readIMU: { model.headTrackImuReadout }, calibrate: { headphones.tapControl() }),
                readLevel: { now, viewFlip in
                    model.liveLevelDisplay(model.session.liveLevelReading.mode(now: now, viewFlip: viewFlip))
                },
                pictureEV: model.livePictureEV
            ) { MonitorOperatorLiveFeedPane<Host>()
            } preview: { model.inspectorPreview(tool: $0)
            } lookMenu: { model.lookMenu() }
            .overlay {
                if model.session.sessionRecovery.isRecovering {
                    SessionRecoveryOverlay<Host>().frame(width: layout.viewport.width, height: layout.viewport.height)
                        .animation(.easeOut(duration: 0.2), value: model.session.sessionRecovery.isRecovering)
                }
            }
            .monitorVideoBackdrop(
                renderer: model.liveBackdrop,
                configuration: [
                    MonitorVideoBackdropConfiguration(
                        source: ObjectIdentifier(model.session.decoder),
                        generation: Int(model.frameSamples.inspectorSourceEpoch),
                        effects: model.assist.effects,
                        geometry: [
                            layout.onFeed.minX, layout.onFeed.minY,
                            layout.onFeed.width, layout.onFeed.height,
                            model.livePictureViewFlip ? 1 : 0,
                            model.portraitFeedAspect == .fill ? 1 : 0,
                        ])
                ],
                enabled: model.shell.cover == nil && !model.assist.gradesClip
                    && !model.isWatchingFeed
                    && !model.session.isFeedWarming
            ) { _ in
                let decoder = model.session.decoder, samples = model.frameSamples
                let epoch = samples.inspectorSourceEpoch
                guard let token = decoder.sourceToken, let buffer = decoder.backdropSource else { return [] }
                let effects = decoder.backdropEffects
                return [
                    MonitorVideoBackdropSource(
                        buffer: buffer, effects: effects,
                        frame: MonitorVideoBackdropSource.displayedFrame(
                            sourceAspect: decoder.pictureAspect, effects: effects, in: layout.onFeed,
                            fill: layout.presentation?.portrait == true
                                && layout.presentation?.fillsPicture == true
                                && decoder.pictureAspect >= 1),
                        clip: layout.onFeed, identity: .live(token: token, epoch: epoch), admission: { [weak decoder, weak samples] in
                            guard let decoder, let samples else { return false }
                            return decoder.sourceToken == token && samples.inspectorSourceEpoch == epoch
                        })
                ]
            }
        }

        private var zoomSource: MonitorOperatorZoomPresentation {
            MonitorOperatorZoomPresentation(maximum: model.session.zoomMax,
                opticalStops: model.session.zoomStops.contains(3) ? [1, 3] : [1],
                caption: model.liveZoomCaption,
                readValue: { model.session.zoomDialReadout },
                readOrigin: { model.session.status.zoomFactor ?? model.session.zoomOptimistic ?? model.session.zoomStop },
                label: { CamFov.displayLabel(factor: $0, ceiling: model.zoomCeiling) })
        }

        private var focusSource: MonitorOperatorFocusSource {
            MonitorOperatorFocusSource(read: {
                let session = model.session
                return MonitorOperatorFocusObservation(point: session.focusPoint, overlay: session.focusOverlay,
                    faces: session.dimmedFaces, resetAvailable: session.isFocusResetAvailable,
                    supportsTapFocus: session.supportsTapFocus, tracking: session.isTracking,
                    search: session.searchBox, subject: session.subjectBox)
            }, cancelTracking: { model.session.cancelSubjectTracking() })
        }
    }

    /// HEVC + LUT/PEAK present. Isolated so 25 Hz decode / 5 Hz status cannot rebuild chrome.
    struct MonitorOperatorLiveFeedPane<Host: MonitorLiveScreenHost>: View {
        @Environment(Host.self) private var model

        private var liveEffects: MonitorFrameEffects {
            var fx = model.assist.effects.withFaceAF(model.session.wantsFaceAF)
            fx.mirror = model.assist.mirrorsHorizontally
            return fx
        }

        var body: some View {
            MonitorLiveVideoView<Host.Picture>(
                decoder: model.session.decoder,
                effects: liveEffects,
                sampleBus: model.frameSamples,
                transfer: LiveMonitorColorScience.transfer(
                    isPhoto: model.session.status.isPhoto,
                    colorMode: model.session.status.colorMode),
                pictureFlip: model.livePictureViewFlip,
                hdrDisplay: model.hdrDisplayActive,
                qualification: { [weak session = model.session] in session?.nativeQualificationSnapshot }
            )
            .onChange(of: model.assist.effects) { _, fx in
                model.session.decoder.effects = fx.withFaceAF(model.session.wantsFaceAF)
            }
            .onChange(of: model.session.wantsFaceAF) { _, wants in
                model.session.decoder.effects = model.assist.effects.withFaceAF(wants)
            }
            .onChange(of: model.session.status.colorMode) { _, _ in
                model.syncLiveMonitorColor()
            }
            .onChange(of: model.session.status.isPhoto) { _, _ in
                model.syncLiveMonitorColor()
            }
            .onChange(of: model.assist.gradesClip) { _, grading in
                if !grading { model.syncLiveMonitorColor() }
            }
        }
    }
#endif
