#if os(iOS)
import MetalKit
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineMedia
import SwiftUI

/// Saved panel composition observes picture samples only inside the plot child.
public struct MonitorScopeOverlay<Looks: MonitorLookProvider>: View {
    private let tool: MonitorAssistSelection
    private let assist: MonitorAssistState<Looks>
    private let stores: AssistPanelStores
    private let haptics: OperatorHaptics
    private let canvas: CGRect
    private let feed: CGRect
    private let clearance: EdgeInsets
    private let readBundle: () -> ScopeAssistBundle
    private let configureDisplay: @MainActor (MTKView) -> MonitorScopeDisplayOptions
    private let paradeIntensityScale: Double
    private let fittedSize: CGSize?
    public init(tool: MonitorAssistSelection, assist: MonitorAssistState<Looks>, stores: AssistPanelStores,
        haptics: OperatorHaptics, canvas: CGRect = .zero, feed: CGRect = .zero,
        chromeClearance: EdgeInsets = EdgeInsets(), readBundle: @escaping () -> ScopeAssistBundle,
        configureDisplay: @escaping @MainActor (MTKView) -> MonitorScopeDisplayOptions = { _ in .sdr },
        fittedSize: CGSize? = nil, paradeIntensityScale: Double = 1) {
        self.tool = tool; self.assist = assist; self.stores = stores; self.haptics = haptics
        self.canvas = canvas; self.feed = feed; self.clearance = chromeClearance
        self.readBundle = readBundle; self.configureDisplay = configureDisplay
        self.paradeIntensityScale = paradeIntensityScale
        self.fittedSize = fittedSize
    }
    @ViewBuilder public var body: some View {
        switch tool {
        case .waveform: waveform
        case .parade: parade
        case .histogram: histogram
        case .vectorscope: vectorscope
        case .trafficLights: trafficLights
        case .ndMeter:
            NDMeterOverlay(stores: stores, bounds: canvas, feed: feed, chromeClearance: clearance,
                reading: { NDAssist.reading(from: readBundle()) })
        default: EmptyView()
        }
    }
    private var hasCanvas: Bool { canvas.width > 1 && canvas.height > 1 }
    @ViewBuilder private var waveform: some View {
        let options = stores.waveform.options
        let size = fittedSize ?? MonitorScopePanelPlacement.size(WaveformAssist.panelSize(scale: stores.waveform.presentationScale(in: canvas)),
            canvas: canvas, clearance: clearance)
        let plot = MonitorScopePanelPlate(title: "Wave", chip: options.mode.rawValue.uppercased(), size: size) {
            MonitorScopeBundleContent(read: readBundle) { bundle in
                MonitorWaveformScopePlot(samples: bundle.samples, trail: bundle.trailSamples,
                    mode: .waveform(options.mode),
                    axis: bundle.levelAxis ?? ScopeLevelAxis(transfer: bundle.transfer, clipByte: bundle.clipByte),
                    revision: bundle.revision, intensity: WaveformAssist.intensity(options.brightness),
                    guides: options.guides, size: size, configureDisplay: configureDisplay)
            }
        }.accessibilityLabel(options.mode == .rgb ? "RGB waveform" : "Luma waveform")
        if hasCanvas {
            WaveformAssist.overlay(stores: stores, haptics: haptics, canvas: canvas, feed: feed,
                chromeClearance: clearance, onOpenOptions: { WaveformAssist.presentOptions(anchor: $0, assist: assist) }) { plot }
        } else { plot }
    }
    @ViewBuilder private var parade: some View {
        let options = stores.parade.options
        let size = fittedSize ?? MonitorScopePanelPlacement.size(ParadeAssist.panelSize(scale: stores.parade.presentationScale(in: canvas)),
            canvas: canvas, clearance: clearance)
        let plot = MonitorScopePanelPlate(title: "Parade", chip: ParadeAssist.chip(options.mode), size: size) {
            MonitorScopeBundleContent(read: readBundle) { bundle in
                MonitorWaveformScopePlot(samples: bundle.samples, trail: bundle.trailSamples,
                    mode: .parade(options.mode),
                    axis: bundle.levelAxis ?? ScopeLevelAxis(transfer: bundle.transfer, clipByte: bundle.clipByte),
                    revision: bundle.revision, intensity: ParadeAssist.intensity(options.brightness, scale: paradeIntensityScale),
                    guides: options.guides, size: size, configureDisplay: configureDisplay)
            }
        }.accessibilityLabel(ParadeAssist.accessibilityLabel(options.mode))
        if hasCanvas { ParadeAssist.overlay(stores: stores, canvas: canvas, feed: feed, chromeClearance: clearance) { plot } }
        else { plot }
    }
    @ViewBuilder private var histogram: some View {
        let options = stores.histogram.options
        let size = fittedSize ?? MonitorScopePanelPlacement.size(HistogramAssist.panelSize(scale: stores.histogram.presentationScale(in: canvas)),
            canvas: canvas, clearance: clearance)
        let plot = MonitorScopePanelPlate(title: HistogramAssist.panelTitle, chip: HistogramAssist.chip, size: size) {
            MonitorScopeBundleContent(read: readBundle) { bundle in
                MonitorHistogramScopePlot(display: bundle.histogramDisplay, traffic: bundle.traffic,
                    showTrafficLights: options.trafficLights && bundle.levelAxis?.supportsCalibratedReferences != false)
            }
        }.accessibilityLabel("RGB histogram, scale 0 to 100")
        if hasCanvas { HistogramAssist.overlay(stores: stores, canvas: canvas, feed: feed, chromeClearance: clearance) { plot } }
        else { plot }
    }
    @ViewBuilder private var vectorscope: some View {
        let options = stores.vectorscope.options
        let size = fittedSize ?? MonitorScopePanelPlacement.size(VectorscopeAssist.panelSize(scale: stores.vectorscope.presentationScale(in: canvas)),
            canvas: canvas, clearance: clearance)
        let plot = MonitorScopePanelPlate(title: "Vector", chip: VectorscopeAssist.chip(zoom: options.zoom), size: size) {
            MonitorScopeBundleContent(read: readBundle) { bundle in
                MonitorVectorscopeScopePlot(points: bundle.vectorscopePoints, trail: bundle.trailVectorscopePoints,
                    zoom: options.zoom, brightness: options.brightness, revision: bundle.revision,
                    configureDisplay: configureDisplay)
            }
        }.accessibilityLabel("Vectorscope")
        if hasCanvas { VectorscopeAssist.overlay(stores: stores, canvas: canvas, feed: feed, chromeClearance: clearance) { plot } }
        else { plot }
    }
    private var trafficLights: some View {
        let store = stores.trafficLights
        let size = MonitorScopePanelPlacement.size(TrafficLightsAssist.panelSize(scale: store.scale), canvas: canvas, clearance: clearance)
        return TrafficLightsMovablePanel(store: store, size: size,
            defaultCenter: MonitorScopePanelCentering.defaultCenter(size: size, bounds: canvas), bounds: canvas,
            placementBounds: MonitorScopePanelPlacement.bounds(in: canvas, clearance: clearance)) {
            MonitorScopeBundleContent(read: readBundle) { bundle in
                if bundle.levelAxis?.supportsCalibratedReferences != false { MonitorTrafficLightsMeter(reading: bundle.traffic) }
            }
        }
    }
}

/// A portrait fit region borrows the same saved scope options and immutable sample values as
/// the floating panels. The source supplies its supported order; placement remains common.
public struct MonitorScopeFitStack<Looks: MonitorLookProvider>: View {
    private let tools: [MonitorAssistSelection]
    private let assist: MonitorAssistState<Looks>
    private let stores: AssistPanelStores
    private let haptics: OperatorHaptics
    private let readBundle: () -> ScopeAssistBundle
    private let configureDisplay: @MainActor (MTKView) -> MonitorScopeDisplayOptions
    private let paradeIntensityScale: Double
    public init(tools: [MonitorAssistSelection], assist: MonitorAssistState<Looks>,
        stores: AssistPanelStores, haptics: OperatorHaptics,
        readBundle: @escaping () -> ScopeAssistBundle,
        configureDisplay: @escaping @MainActor (MTKView) -> MonitorScopeDisplayOptions = { _ in .sdr },
        paradeIntensityScale: Double = 1) {
        self.tools = tools; self.assist = assist; self.stores = stores; self.haptics = haptics
        self.readBundle = readBundle; self.configureDisplay = configureDisplay
        self.paradeIntensityScale = paradeIntensityScale
    }
    public var body: some View {
        VStack(spacing: 8) {
            ForEach(tools, id: \.self) { tool in
                GeometryReader { geometry in
                    if tool == .trafficLights {
                        MonitorScopeBundleContent(read: readBundle) {
                            if $0.levelAxis?.supportsCalibratedReferences != false {
                                MonitorTrafficLightsMeter(reading: $0.traffic, fillsWidth: true)
                            }
                        }
                    } else {
                        MonitorScopeOverlay(tool: tool, assist: assist, stores: stores, haptics: haptics,
                            readBundle: readBundle, configureDisplay: configureDisplay, fittedSize: geometry.size, paradeIntensityScale: paradeIntensityScale)
                    }
                }
            }
        }
    }
}

private struct MonitorScopeBundleContent<Content: View>: View {
    let read: () -> ScopeAssistBundle
    let content: (ScopeAssistBundle) -> Content
    init(read: @escaping () -> ScopeAssistBundle, @ViewBuilder content: @escaping (ScopeAssistBundle) -> Content) {
        self.read = read; self.content = content
    }
    var body: some View { content(read()) }
}

/// Shared visibility order around one measured source. Native ports only publish immutable bundles.
public struct MonitorScopeOverlays<Looks: MonitorLookProvider>: View {
    private let assist: MonitorAssistState<Looks>
    private let stores: AssistPanelStores
    private let haptics: OperatorHaptics
    private let canvas: CGRect
    private let feed: CGRect
    private let clearance: EdgeInsets
    private let readBundle: () -> ScopeAssistBundle
    private let configureDisplay: @MainActor (MTKView) -> MonitorScopeDisplayOptions
    private let paradeIntensityScale: Double
    private let playback: Bool
    private let available: Set<MonitorAssistSelection>
    public init(assist: MonitorAssistState<Looks>, stores: AssistPanelStores, haptics: OperatorHaptics,
        canvas: CGRect, feed: CGRect, chromeClearance: EdgeInsets = EdgeInsets(),
        readBundle: @escaping () -> ScopeAssistBundle,
        configureDisplay: @escaping @MainActor (MTKView) -> MonitorScopeDisplayOptions = { _ in .sdr },
        playback: Bool = false,
        available: Set<MonitorAssistSelection> = [.waveform, .parade, .vectorscope, .histogram, .trafficLights, .ndMeter],
        paradeIntensityScale: Double = 1) {
        self.assist = assist; self.stores = stores; self.haptics = haptics
        self.canvas = canvas; self.feed = feed; self.clearance = chromeClearance
        self.readBundle = readBundle; self.configureDisplay = configureDisplay
        self.paradeIntensityScale = paradeIntensityScale
        self.playback = playback
        self.available = available
    }
    public var body: some View {
        ForEach([MonitorAssistSelection.waveform, .parade, .vectorscope, .histogram, .trafficLights, .ndMeter], id: \.self) { tool in
            if available.contains(tool) && (playback ? assist.isPlaybackVisible(tool) : assist.isVisible(tool)) {
                MonitorScopeOverlay(tool: tool, assist: assist, stores: stores, haptics: haptics,
                    canvas: canvas, feed: feed, chromeClearance: clearance, readBundle: readBundle,
                    configureDisplay: configureDisplay, paradeIntensityScale: paradeIntensityScale)
            }
        }
    }
}
#endif
