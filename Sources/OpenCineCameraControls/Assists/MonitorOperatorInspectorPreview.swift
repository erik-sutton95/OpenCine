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
    let lookContext: LUTPickerContext?
}

/// The existing official-look preview interface remains source compatible.
public typealias MonitorOperatorInspectorPreview = MonitorLookInspectorPreview<MonitorLUTLooks>

/// Complete draw-only inspector preview. Native preparation is one bounded
/// source/effects port; scopes consume the existing immutable sample bundle.
public struct MonitorLookInspectorPreview<Looks: MonitorLookProvider>: View {
    private let tool: MonitorAssistSelection
    private let assist: MonitorAssistState<Looks>
    private let stores: AssistPanelStores
    private let haptics: OperatorHaptics
    private let source: MonitorInspectorImageSource
    private let readCustomName: @MainActor () -> String?
    private let readLookContext: @MainActor () -> LUTPickerContext?
    private let pictureEffects: MonitorFrameEffects?
    private let prepareEffects: @MainActor (MonitorInspectorImageFrame) -> MonitorFrameEffects
    private let readBundle: @MainActor () -> ScopeAssistBundle
    private let readAudio: @MainActor () -> AudioMeterLevels?
    private let readAudioSensitivity: @MainActor () -> String?
    private let configureDisplay: @MainActor (MTKView) -> MonitorScopeDisplayOptions
    private let onImage: @MainActor (CGImage?) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.audioInspectorLevels) private var audioInspectorLevels
    @State private var session = MonitorInspectorPreviewSession<MonitorInspectorImageMeaning<Looks.Selection>>()
    @State private var availableWidth: CGFloat = 0

    public init(tool: MonitorAssistSelection, assist: MonitorAssistState<Looks>,
        stores: AssistPanelStores, haptics: OperatorHaptics,
        source: MonitorInspectorImageSource, readCustomName: @escaping @MainActor () -> String?,
        readLookContext: @escaping @MainActor () -> LUTPickerContext?,
        pictureEffects: MonitorFrameEffects? = nil,
        prepareEffects: @escaping @MainActor (MonitorInspectorImageFrame) -> MonitorFrameEffects,
        readBundle: @escaping @MainActor () -> ScopeAssistBundle,
        readAudio: @escaping @MainActor () -> AudioMeterLevels? = { nil },
        readAudioSensitivity: @escaping @MainActor () -> String? = { nil },
        configureDisplay: @escaping @MainActor (MTKView) -> MonitorScopeDisplayOptions = { _ in .sdr },
        onImage: @escaping @MainActor (CGImage?) -> Void = { _ in }) {
        self.tool = tool; self.assist = assist; self.stores = stores; self.haptics = haptics
        self.source = source; self.readCustomName = readCustomName; self.pictureEffects = pictureEffects
        self.readLookContext = readLookContext
        self.prepareEffects = prepareEffects; self.readBundle = readBundle
        self.readAudio = readAudio; self.readAudioSensitivity = readAudioSensitivity
        self.configureDisplay = configureDisplay; self.onImage = onImage
    }

    private var isActive: Bool { scenePhase == .active && assist.inspectorSceneActive }
    private var meaning: MonitorInspectorImageMeaning<Looks.Selection>? {
        guard isActive, MonitorInspectorPreviewPolicy.isImage(tool),
            let snapshot = source.snapshot else { return nil }
        return MonitorInspectorImageMeaning(source: snapshot.source, epoch: snapshot.epoch,
            playback: snapshot.playback, tool: tool,
            options: pictureEffects ?? assist.inspectorImageOptions(tool: tool,
                transfer: snapshot.transfer,
                clipByte: snapshot.exposureCeiling.clipByte(transfer: snapshot.transfer)),
            transfer: snapshot.transfer, selection: assist.looks.selection,
            exposureStops: assist.lutExposureStops, customName: readCustomName(),
            lookContext: readLookContext())
    }

    private struct Activity: Equatable {
        let tool: MonitorAssistSelection
        let source: MonitorInspectorImageSource.Identity
    }
    private var activity: Activity? {
        isActive && MonitorInspectorPreviewPolicy.isImage(tool)
            ? Activity(tool: tool, source: source.identity) : nil
    }

    public var body: some View {
        previewBody
            .frame(maxWidth: .infinity)
            .frame(height: CGFloat(MonitorInspectorPreviewPolicy.height(width: Double(availableWidth), tool: tool)))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            .background(MonitorTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(MonitorTheme.border))
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(tool.title) preview")
            .accessibilityAddTraits(.isImage)
            .accessibilityIdentifier("monitor.inspector.preview")
            .accessibilityValue(previewAvailable ? "Picture" : "Waiting for picture")
            .task(id: activity) {
                guard activity != nil else { return }
                synchronize()
                await session.run(source: source)
            }
            .onChange(of: meaning) { _, _ in synchronize() }
            .onChange(of: previewImage.map(ObjectIdentifier.init)) { _, _ in
                onImage(previewImage)
            }
            .onDisappear { session.deactivate() }
    }

    private var previewImage: CGImage? {
        meaning.flatMap { session.image(matching: $0) }
    }

    private var previewAvailable: Bool {
        if MonitorInspectorPreviewPolicy.isImage(tool) {
            return meaning.flatMap { session.image(matching: $0) } != nil
        }
        if tool == .audioMeters { return audioInspectorLevels != nil || readAudio() != nil }
        return readBundle() != .empty
    }

    private func synchronize() {
        session.synchronize(currentMeaning: { meaning }) { frame in
            pictureEffects ?? prepareEffects(frame)
        }
    }

    @ViewBuilder private var previewBody: some View {
        if MonitorInspectorPreviewPolicy.isImage(tool) { imagePreview }
        else { scopePreview }
    }

    @ViewBuilder private var imagePreview: some View {
        if let meaning, let image = session.image(matching: meaning) {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                .overlay {
                    GeometryReader { proxy in
                        let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
                        let width = min(proxy.size.width, proxy.size.height * aspect)
                        let height = width / aspect
                        let frame = CGRect(x: (proxy.size.width - width) / 2,
                            y: (proxy.size.height - height) / 2, width: width, height: height)
                        imageMarks(frame: frame)
                    }
                }
        } else { waiting("Waiting for picture") }
    }

    @ViewBuilder private func imageMarks(frame: CGRect) -> some View {
        switch tool {
        case .guides: GuidesAssist.overlay(feed: frame, assist: assist, fallback: assist.guideAspect)
        case .grid: GridAssist.overlay(feed: frame, thirds: assist.gridThirds,
            phi: assist.gridPhi, diagonal: assist.gridDiagonal)
        case .crosshair: CrosshairAssist.overlay(feed: frame)
        default: EmptyView()
        }
    }

    @ViewBuilder private var scopePreview: some View {
        switch tool {
        case .waveform:
            fittedScope(size: WaveformAssist.panelSize(scale: stores.waveform.options.scale)) { scopePlot }
        case .parade:
            fittedScope(size: ParadeAssist.panelSize(scale: stores.parade.options.scale)) { scopePlot }
        case .histogram:
            fittedScope(size: HistogramAssist.panelSize(scale: stores.histogram.options.scale)) { scopePlot }
        case .vectorscope:
            fittedScope(size: VectorscopeAssist.panelSize(scale: stores.vectorscope.options.scale)) { scopePlot }
        case .trafficLights:
            MonitorTrafficLightsMeter(reading: readBundle().traffic).frame(width: 88, height: 120)
        case .ndMeter:
            NDMeterChip(reading: NDAssist.reading(from: readBundle()), notation: stores.nd.notation)
                .frame(width: 120, height: 44)
        case .audioMeters: audioPreview
        default: EmptyView()
        }
    }

    private var scopePlot: some View {
        MonitorScopeOverlay(tool: tool, assist: assist, stores: stores, haptics: haptics,
            readBundle: readBundle, configureDisplay: configureDisplay)
    }

    @ViewBuilder private var audioPreview: some View {
        if let levels = audioInspectorLevels ?? (assist.gradesClip ? nil : readAudio()) {
            let options = stores.audio.options
            fittedScope(size: AudioAssist.panelSize(orientation: options.orientation)) {
                AudioMetersPanelMini(levels: levels,
                    sensitivity: audioInspectorLevels == nil && !assist.gradesClip ? readAudioSensitivity() : nil,
                    orientation: options.orientation, showsDB: options.showsDB)
            }
        } else { waiting("Waiting for audio") }
    }

    private func waiting(_ title: String) -> some View {
        Text(title).font(MonitorTheme.font(11)).foregroundStyle(MonitorTheme.muted)
    }

    private func fittedScope<Content: View>(size: CGSize, @ViewBuilder content: () -> Content) -> some View {
        let plot = content()
        return GeometryReader { proxy in
            let scale = min(1, max(1, proxy.size.width - 16) / max(1, size.width),
                max(1, proxy.size.height - 16) / max(1, size.height))
            plot.frame(width: size.width, height: size.height).scaleEffect(scale)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }
}

extension MonitorLookInspectorPreview where Looks == MonitorLUTLooks {
    /// The original initializer retains all official-look preparation facts and callbacks.
    public init(tool: MonitorAssistSelection, assist: MonitorAssistState<MonitorLUTLooks>,
        stores: AssistPanelStores, haptics: OperatorHaptics,
        source: MonitorInspectorImageSource, readCustomName: @escaping @MainActor () -> String?,
        pictureEffects: MonitorFrameEffects? = nil,
        prepareEffects: @escaping @MainActor (MonitorInspectorImageFrame) -> MonitorFrameEffects,
        readBundle: @escaping @MainActor () -> ScopeAssistBundle,
        readAudio: @escaping @MainActor () -> AudioMeterLevels? = { nil },
        readAudioSensitivity: @escaping @MainActor () -> String? = { nil },
        configureDisplay: @escaping @MainActor (MTKView) -> MonitorScopeDisplayOptions = { _ in .sdr }) {
        self.init(tool: tool, assist: assist, stores: stores, haptics: haptics,
            source: source, readCustomName: readCustomName,
            readLookContext: {
                LUTPickerContext(colorMode: assist.monitorColorMode, isPhoto: assist.looks.liveIsPhoto,
                    inPlayback: assist.gradesClip, family: assist.monitorFamily,
                    cameraName: assist.monitorCameraName, isWatching: false)
            }, pictureEffects: pictureEffects, prepareEffects: prepareEffects,
            readBundle: readBundle, readAudio: readAudio,
            readAudioSensitivity: readAudioSensitivity, configureDisplay: configureDisplay)
    }
}
#endif
