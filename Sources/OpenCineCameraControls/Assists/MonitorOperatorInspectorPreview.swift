#if os(iOS)
    import MetalKit
    import MonitorPresentation
    import MonitorUI
    import OpenCineAppKit
    import OpenCineAppKitApple
    import OpenCineCameraVocabulary
    import OpenCineMedia
    import SwiftUI

    /// Cheap image meaning; LUT preparation remains inside the native admission.
    private struct MonitorInspectorImageMeaning<Selection: Equatable>: Equatable {
        let source: ObjectIdentifier
        let epoch: UInt64
        let playback: Bool
        let tool: MonitorAssistSelection
        let options: MonitorFrameEffects
        let transfer: MonitorTransfer
        let selection: Selection
        let exposureStops: Double
        let customName: String?
        let lookIdentity: AnyHashable?
    }

    /// Complete draw-only inspector preview. Native preparation is one bounded
    /// source/effects port; scopes consume the existing immutable sample bundle.
    public struct MonitorLookInspectorPreview<Looks: MonitorLookProvider>: View {
        private let tool: MonitorAssistSelection
        private let assist: MonitorAssistState<Looks>
        private let stores: AssistPanelStores
        private let haptics: OperatorHaptics
        private let source: MonitorInspectorImageSource?
        private let renderedPicture: MonitorInspectorRenderedPictureSource?
        private let readLookIdentity: @MainActor () -> AnyHashable?
        private let readCustomName: @MainActor () -> String?
        private let pictureEffects: MonitorFrameEffects?
        private let prepareEffects: @MainActor (MonitorInspectorImageFrame) -> MonitorFrameEffects
        private let readBundle: @MainActor () -> ScopeAssistBundle
        private let readAudio: @MainActor () -> AudioMeterLevels?
        private let readAudioSensitivity: @MainActor () -> String?
        private let configureDisplay: @MainActor (MTKView) -> MonitorScopeDisplayOptions
        @Environment(\.scenePhase) private var scenePhase
        @Environment(\.audioInspectorLevels) private var audioInspectorLevels
        @State private var session = MonitorInspectorPreviewSession<
            MonitorInspectorImageMeaning<Looks.Selection>
        >()
        @State private var availableWidth: CGFloat = 0

        public init(
            tool: MonitorAssistSelection, assist: MonitorAssistState<Looks>,
            stores: AssistPanelStores, haptics: OperatorHaptics,
            source: MonitorInspectorImageSource, readCustomName: @escaping @MainActor () -> String?,
            pictureEffects: MonitorFrameEffects? = nil,
            prepareEffects:
                @escaping @MainActor (MonitorInspectorImageFrame) -> MonitorFrameEffects,
            readBundle: @escaping @MainActor () -> ScopeAssistBundle,
            readAudio: @escaping @MainActor () -> AudioMeterLevels? = { nil },
            readAudioSensitivity: @escaping @MainActor () -> String? = { nil },
            configureDisplay: @escaping @MainActor (MTKView) -> MonitorScopeDisplayOptions = { _ in
                .sdr
            },
            readLookIdentity: @escaping @MainActor () -> AnyHashable? = { nil }
        ) {
            self.tool = tool
            self.assist = assist
            self.stores = stores
            self.haptics = haptics
            self.source = source
            self.renderedPicture = nil
            self.readLookIdentity = readLookIdentity
            self.readCustomName = readCustomName
            self.pictureEffects = pictureEffects
            self.prepareEffects = prepareEffects
            self.readBundle = readBundle
            self.readAudio = readAudio
            self.readAudioSensitivity = readAudioSensitivity
            self.configureDisplay = configureDisplay
        }

        /// A source-calibrated native image adapter. UI receives immutable pictures and a scoped task;
        /// native ownership and rendering remain in the host, with no sample bus entering a view.
        public init(
            tool: MonitorAssistSelection, assist: MonitorAssistState<Looks>,
            stores: AssistPanelStores, haptics: OperatorHaptics,
            picture: MonitorInspectorRenderedPictureSource,
            readBundle: @escaping @MainActor () -> ScopeAssistBundle,
            readAudio: @escaping @MainActor () -> AudioMeterLevels? = { nil },
            readAudioSensitivity: @escaping @MainActor () -> String? = { nil },
            configureDisplay: @escaping @MainActor (MTKView) -> MonitorScopeDisplayOptions = { _ in
                .sdr
            }
        ) {
            self.tool = tool
            self.assist = assist
            self.stores = stores
            self.haptics = haptics
            source = nil
            renderedPicture = picture
            readLookIdentity = { nil }
            readCustomName = { nil }
            pictureEffects = nil
            prepareEffects = { _ in .init() }
            self.readBundle = readBundle
            self.readAudio = readAudio
            self.readAudioSensitivity = readAudioSensitivity
            self.configureDisplay = configureDisplay
        }

        private var isActive: Bool { scenePhase == .active && assist.inspectorSceneActive }
        private var meaning: MonitorInspectorImageMeaning<Looks.Selection>? {
            guard isActive, MonitorInspectorPreviewPolicy.isImage(tool),
                let snapshot = source?.snapshot
            else { return nil }
            return MonitorInspectorImageMeaning(
                source: snapshot.source, epoch: snapshot.epoch,
                playback: snapshot.playback, tool: tool,
                options: pictureEffects
                    ?? assist.inspectorImageOptions(
                        tool: tool,
                        transfer: snapshot.transfer,
                        clipByte: snapshot.exposureCeiling.clipByte(transfer: snapshot.transfer)),
                transfer: snapshot.transfer, selection: assist.looks.selection,
                exposureStops: assist.lutExposureStops, customName: readCustomName(),
                lookIdentity: readLookIdentity())
        }

        private enum Activity: Hashable {
            case samples(MonitorAssistSelection, MonitorInspectorImageSource.Identity)
            case rendered(MonitorAssistSelection, MonitorInspectorRenderedPictureSource.Identity)
        }
        private var activity: Activity? {
            guard isActive, MonitorInspectorPreviewPolicy.isImage(tool) else { return nil }
            if let source { return .samples(tool, source.identity) }
            return renderedPicture?.identity.map { .rendered(tool, $0) }
        }

        private var accessibilityValue: String {
            guard MonitorInspectorPreviewPolicy.isImage(tool) else { return "" }
            if renderedPicture != nil {
                return isActive && renderedPicture?.read() != nil
                    ? "Picture" : "Waiting for picture"
            }
            return meaning.flatMap { session.image(matching: $0) } != nil
                ? "Picture" : "Waiting for picture"
        }

        public var body: some View {
            previewBody
                .frame(maxWidth: .infinity)
                .frame(
                    height: CGFloat(
                        MonitorInspectorPreviewPolicy.height(
                            width: Double(availableWidth), tool: tool))
                )
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    availableWidth = $0
                }
                .background(MonitorTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(MonitorTheme.border))
                .allowsHitTesting(false)
                .modifier(
                    MonitorInspectorPreviewAccessibility(
                        title: tool.title,
                        imageValue: renderedPicture != nil
                            && MonitorInspectorPreviewPolicy.isImage(tool)
                            ? accessibilityValue : nil)
                )
                .task(id: activity) {
                    guard activity != nil else { return }
                    if let source {
                        synchronize()
                        await session.run(source: source)
                    } else if let renderedPicture {
                        await renderedPicture.run()
                    }
                }
                .onChange(of: meaning) { _, _ in synchronize() }
                .onDisappear { session.deactivate() }
        }

        private func synchronize() {
            session.synchronize(
                currentMeaning: { meaning },
                effects: { frame in
                    pictureEffects ?? prepareEffects(frame)
                })
        }

        @ViewBuilder private var previewBody: some View {
            if MonitorInspectorPreviewPolicy.isImage(tool) { imagePreview } else { scopePreview }
        }

        @ViewBuilder private var imagePreview: some View {
            if let renderedPicture {
                if isActive, let picture = renderedPicture.read() {
                    image(
                        picture.image, aspectMultiplier: picture.aspectMultiplier,
                        mirrorHorizontal: picture.mirrorHorizontal,
                        mirrorVertical: picture.mirrorVertical)
                } else {
                    waiting("Waiting for picture")
                }
            } else if let meaning, let picture = session.image(matching: meaning) {
                image(picture)
            } else {
                waiting("Waiting for picture")
            }
        }

        private func image(
            _ image: CGImage, aspectMultiplier: Double = 1,
            mirrorHorizontal: Bool = false, mirrorVertical: Bool = false
        ) -> some View {
            Image(decorative: image, scale: 1).resizable()
                .aspectRatio(
                    CGFloat(image.width) / CGFloat(max(1, image.height))
                        * CGFloat(aspectMultiplier), contentMode: .fit
                )
                .scaleEffect(x: mirrorHorizontal ? -1 : 1, y: mirrorVertical ? -1 : 1)
                .overlay {
                    GeometryReader { proxy in
                        let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
                        let width = min(proxy.size.width, proxy.size.height * aspect)
                        let height = width / aspect
                        let frame = CGRect(
                            x: (proxy.size.width - width) / 2,
                            y: (proxy.size.height - height) / 2, width: width, height: height)
                        imageMarks(frame: frame)
                    }
                }
        }

        @ViewBuilder private func imageMarks(frame: CGRect) -> some View {
            switch tool {
            case .guides:
                GuidesAssist.overlay(feed: frame, assist: assist, fallback: assist.guideAspect)
            case .grid:
                GridAssist.overlay(
                    feed: frame, thirds: assist.gridThirds,
                    phi: assist.gridPhi, diagonal: assist.gridDiagonal)
            case .crosshair: CrosshairAssist.overlay(feed: frame)
            default: EmptyView()
            }
        }

        @ViewBuilder private var scopePreview: some View {
            switch tool {
            case .waveform:
                fittedScope(size: WaveformAssist.panelSize(scale: stores.waveform.options.scale)) {
                    scopePlot
                }
            case .parade:
                fittedScope(size: ParadeAssist.panelSize(scale: stores.parade.options.scale)) {
                    scopePlot
                }
            case .histogram:
                fittedScope(size: HistogramAssist.panelSize(scale: stores.histogram.options.scale))
                { scopePlot }
            case .vectorscope:
                fittedScope(
                    size: VectorscopeAssist.panelSize(scale: stores.vectorscope.options.scale)
                ) { scopePlot }
            case .trafficLights:
                MonitorTrafficLightsMeter(reading: readBundle().traffic).frame(
                    width: 88, height: 120)
            case .ndMeter:
                NDMeterChip(
                    reading: NDAssist.reading(from: readBundle()), notation: stores.nd.notation
                )
                .frame(width: 120, height: 44)
            case .audioMeters: audioPreview
            default: EmptyView()
            }
        }

        private var scopePlot: some View {
            MonitorScopeOverlay(
                tool: tool, assist: assist, stores: stores, haptics: haptics,
                readBundle: readBundle, configureDisplay: configureDisplay)
        }

        @ViewBuilder private var audioPreview: some View {
            if let levels = audioInspectorLevels ?? (assist.gradesClip ? nil : readAudio()) {
                let options = stores.audio.options
                fittedScope(size: AudioAssist.panelSize(orientation: options.orientation)) {
                    AudioMetersPanelMini(
                        levels: levels,
                        sensitivity: audioInspectorLevels == nil && !assist.gradesClip
                            ? readAudioSensitivity() : nil,
                        orientation: options.orientation, showsDB: options.showsDB)
                }
            } else {
                waiting("Waiting for audio")
            }
        }

        private func waiting(_ title: String) -> some View {
            Text(title).font(MonitorTheme.font(11)).foregroundStyle(MonitorTheme.muted)
        }

        private func fittedScope<Content: View>(size: CGSize, @ViewBuilder content: () -> Content)
            -> some View
        {
            let plot = content()
            return GeometryReader { proxy in
                let scale = min(
                    1, max(1, proxy.size.width - 16) / max(1, size.width),
                    max(1, proxy.size.height - 16) / max(1, size.height))
                plot.frame(width: size.width, height: size.height).scaleEffect(scale)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
    }
    private struct MonitorInspectorPreviewAccessibility: ViewModifier {
        let title: String
        let imageValue: String?

        @ViewBuilder func body(content: Content) -> some View {
            if let imageValue {
                content.accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityLabel("\(title) preview")
                    .accessibilityValue(imageValue)
                    .accessibilityIdentifier("monitor.inspector.preview")
            } else {
                content.accessibilityElement(children: .combine)
                    .accessibilityLabel("\(title) preview")
                    .accessibilityIdentifier("monitor.inspector.preview")
            }
        }
    }

    /// Published official-look preview call form retained for existing app source and explicit types.
    public struct MonitorOperatorInspectorPreview: View {
        private let content: MonitorLookInspectorPreview<MonitorLUTLooks>

        public init(
            tool: MonitorAssistSelection, assist: MonitorAssistState<MonitorLUTLooks>,
            stores: AssistPanelStores, haptics: OperatorHaptics,
            source: MonitorInspectorImageSource, readCustomName: @escaping @MainActor () -> String?,
            pictureEffects: MonitorFrameEffects? = nil,
            prepareEffects:
                @escaping @MainActor (MonitorInspectorImageFrame) -> MonitorFrameEffects,
            readBundle: @escaping @MainActor () -> ScopeAssistBundle,
            readAudio: @escaping @MainActor () -> AudioMeterLevels? = { nil },
            readAudioSensitivity: @escaping @MainActor () -> String? = { nil },
            configureDisplay: @escaping @MainActor (MTKView) -> MonitorScopeDisplayOptions = { _ in
                .sdr
            }
        ) {
            content = MonitorLookInspectorPreview(
                tool: tool, assist: assist, stores: stores,
                haptics: haptics, source: source, readCustomName: readCustomName,
                pictureEffects: pictureEffects, prepareEffects: prepareEffects,
                readBundle: readBundle,
                readAudio: readAudio, readAudioSensitivity: readAudioSensitivity,
                configureDisplay: configureDisplay,
                readLookIdentity: {
                    AnyHashable([
                        AnyHashable(assist.monitorColorMode), AnyHashable(assist.monitorFamily),
                        AnyHashable(assist.monitorCameraName),
                    ])
                })
        }

        public var body: some View { content }
    }

    /// An immutable rendered picture and the geometry this source's calibration requires.
    @MainActor public struct MonitorInspectorRenderedPicture {
        public let image: CGImage
        public let aspectMultiplier: Double
        public let mirrorHorizontal: Bool
        public let mirrorVertical: Bool

        public init(
            image: CGImage, aspectMultiplier: Double = 1,
            mirrorHorizontal: Bool = false, mirrorVertical: Bool = false
        ) {
            self.image = image
            self.aspectMultiplier = aspectMultiplier
            self.mirrorHorizontal = mirrorHorizontal
            self.mirrorVertical = mirrorVertical
        }
    }

    /// A borrowed native renderer. The shared view cancels `run` when this source or tool retires.
    /// `read` must return only a picture still matching the current source and option meaning.
    @MainActor public struct MonitorInspectorRenderedPictureSource {
        public struct Identity: Hashable {
            public let source: ObjectIdentifier
            public let presentation: UUID
            public init(source: ObjectIdentifier, presentation: UUID) {
                self.source = source
                self.presentation = presentation
            }
        }
        public let identity: Identity?
        fileprivate let read: @MainActor () -> MonitorInspectorRenderedPicture?
        fileprivate let run: @MainActor () async -> Void

        public init(
            identity: Identity?,
            read: @escaping @MainActor () -> MonitorInspectorRenderedPicture?,
            run: @escaping @MainActor () async -> Void
        ) {
            self.identity = identity
            self.read = read
            self.run = run
        }
    }
#endif
