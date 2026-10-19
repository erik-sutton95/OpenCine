import Foundation
import MonitorPresentation
import Observation
import OpenCineMedia

/// Source/catalog interpretation varies; the shared owner prepares the actual media cube.
@MainActor
public protocol MonitorLookProvider: AnyObject {
    associatedtype Selection: Equatable
    var selection: Selection { get }
    var cube: CubeLUT? { get }
    var transfer: MonitorTransfer { get }
    var referenceClipByte: Int { get }
    func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer
    /// Whether the picture this provider's host draws honours `lutExposureStops` before its cube.
    /// The look comparison offers its Exposure control only when it does (A1-37).
    var appliesLUTExposure: Bool { get }
    /// The curve the source has reported, or nil while it is unknown (product ruling 2026-10-16):
    /// false colour, zebra and LUT exposure wait for it.
    var sourceTransfer: MonitorTransfer? { get }
}

extension MonitorLookProvider {
    /// Existing providers retain the input-exposure control until they declare otherwise.
    public var appliesLUTExposure: Bool { true }
    /// A provider that declares no source fact always knows its curve.
    public var sourceTransfer: MonitorTransfer? { transfer }
}

extension MonitorAssistSelection {
    /// The tools that read the source curve (product ruling 2026-10-16; Kotlin twin
    /// `MonitorAssistTool.readsSourceCurve`). While it is unknown they are neither offered nor drawn.
    public static let readsSourceCurve: Set<MonitorAssistSelection> = [.falseColor, .zebra]
}

public struct MonitorAssistPreferenceKeys: Sendable {
    public let assist: String
    public let cleanPins: String
    public let playback: String
    public init(assist: String, cleanPins: String, playback: String) {
        precondition(!assist.isEmpty && !cleanPins.isEmpty && !playback.isEmpty)
        self.assist = assist; self.cleanPins = cleanPins; self.playback = playback
    }
}

/// The option values a fresh install and each settings card's Reset land on. Most apps take the
/// shared `standard` set; an app whose cameras shipped other defaults declares its own, so its
/// operators keep the defaults they had. A value the operator saved always wins over these.
///
/// Kotlin mirror: `MonitorAssistDefaults` in `:appkit`, same names.
public struct MonitorAssistDefaults: Hashable, Sendable {
    /// Highlight zebra threshold, in monitor IRE.
    public var zebraHighlightIRE: Double
    /// Crush and clip tolerance shared by the histogram's traffic lights and the LIGHTS tool.
    public var crushClipCompensation: MonitorCrushClipCompensation

    public init(
        zebraHighlightIRE: Double = LiveZebra.highlightIRE,
        crushClipCompensation: MonitorCrushClipCompensation = .zero
    ) {
        self.zebraHighlightIRE = zebraHighlightIRE
        self.crushClipCompensation = crushClipCompensation
    }

    /// The shared defaults, for an app that declares none.
    public static let standard = Self()
}

/// Owns operator state, independent live/playback visibility, saved schema and LUT preparation.
@available(macOS 14, *)
@MainActor @Observable
public final class MonitorAssistState<Looks: MonitorLookProvider> {
    public var peaking = false
    public var zebra = false
    public var falseColor = false
    public var histogram = false
    public var waveform = false
    public var parade = false
    public var vectorscope = false
    public var trafficLights = false
    public var ndMeter = false
    public var evMeter = false
    public var audioMeters = false
    public var grid = false
    public var crosshair = false
    public var guides = false
    public var level = false
    public var desqueeze = false
    public var mirror = false
    /// MIRROR axes. Tap toggles the tool; the options pick which axes it flips.
    public var mirrorHorizontal = true
    public var mirrorVertical = false
    public var instantReview = false
    public var guideAspect: MonitorGuideAspect = .cinema
    public var guideFamily: MonitorGuideFamily = .film
    public var selectedGuides: Set<MonitorGuideAspect> = [.cinema]
    public var guideMask = false
    public var gridThirds = true
    public var gridPhi = false
    public var gridDiagonal = false
    public var peakingColor: MonitorPeakingColor = .red
    public var peakingSensitivity: MonitorPeakingSense = .medium
    public var falseColorScale: MonitorFalseColorSelection = .sceneStops
    public var falseColorReference = true
    /// Video / IRE read log through the official Rec.709 look (709) or the signal (LOG).
    /// Per assist state: renderers read it from the effects, never from a global.
    public var falseColorRec709 = false
    public var zebraHighlight = true
    public var zebraMidtone = true
    public var zebraHighlightIRE: Double = LiveZebra.highlightIRE
    public var zebraMidtoneIRE: Double = LiveZebra.midtoneIRE
    public var zebraHighlightColor: MonitorZebraPaint = .white
    public var zebraMidtoneColor: MonitorZebraPaint = .amber
    public var desqueezeFactor: Double = 1.33
    public var desqueezeHorizontal = true
    public var desqueezeCustom = false
    public var desqueezeCustomFactor: Double = 1.33
    public var splitComparison = false
    public var splitVertical = true
    /// Input-referred LUT stops (−3…+3, half-stop). 0 is the cube as shipped.
    public var lutExposureStops: Double = 0
    public var clean = false
    /// View-assist tools that stay on the picture in DISP 2. Filter only; never mutates `isOn`.
    public var cleanViewPinnedTools: Set<MonitorAssistSelection> = MonitorAssistState<Looks>.cleanViewDefaultPinnedTools
    public var playbackVisibleTools: Set<MonitorAssistSelection> = []
    public var showLUTPicker = false
    public var configureTool: MonitorAssistSelection? {
        didSet { if configureTool != .lut { inspectorLUTCache = nil } }
    }
    /// Icon (or toolbar) frame in `LiveCanvasSpace` for the long-press options popup.
    public var longPressAnchorRect = MonitorRect(x: 0, y: 0, width: 0, height: 0)
    public var crushClipCompensation = MonitorCrushClipCompensation.zero
    public var trafficLightsScale = 1.0
    public var trafficLightsPosition: MonitorScopeStoredCenter?
    public var lutEnabled = true
    /// The camera reports no metered EV, so the EV meter reads the picture.
    public var evMeterFromPicture = false
    /// The camera reports audio levels (AUDIO in the live rail and View Assist list).
    public var cameraHasAudio = true
    /// Media player is grading a clip (connected or not). LUT sheet must not
    /// restamp Auto from the live SET; disconnected has no `inPlayback` flag.
    public var gradesClip = false
    /// Inspector-only sampling follows the active scene and its visible source.
    /// Picture effects keep their existing lifetime beneath operator pages.
    public var inspectorSceneActive = true
    /// Settings or Media covers the live page. Scope taps and rasters have no
    /// viewer there; looks, Face AF, Watch and relay keep their demand, and the
    /// shared VT decoder stays up, so reveal needs no enable.
    public var liveCovered = false
    public var allowsTransferInference = true

    /// Whether the source has reported its curve. Until it has, false colour and zebra are not
    /// offered or drawn and the LUT bakes without input exposure; the operator's choices stay and
    /// return on their own once the curve is known.
    public var sourceCurveKnown: Bool { looks.sourceTransfer != nil }

    /// Whether a surface offers `tool` now: a curve-reading tool waits for a known source curve.
    public func offers(_ tool: MonitorAssistSelection) -> Bool {
        sourceCurveKnown || !MonitorAssistSelection.readsSourceCurve.contains(tool)
    }

    /// The input exposure the picture applies: none while the source curve is unknown.
    private var appliedLUTExposureStops: Double { sourceCurveKnown ? lutExposureStops : 0 }

    private func showsScopes(_ tool: MonitorAssistSelection) -> Bool {
        !liveCovered && isVisible(tool)
    }

    @ObservationIgnored private var lutCube: CubeLUT?
    @ObservationIgnored private var lutDimension = 0
    @ObservationIgnored private var lutRGBA = Data()
    @ObservationIgnored private var lastSaved: Data?
    @ObservationIgnored private var inspectorLUTCache: InspectorLUTCache?

    /// Cached preparation fact, independent of clean pins and live/playback visibility.
    /// Querying this property never resolves or prepares a cube.
    public var hasPreparedLUT: Bool { lutDimension >= 2 }

    public var lutArmed: Bool { lutEnabled }

    /// Flags are what the monitor *shows*; DISP 2 applies the pin filter here.
    public var effects: MonitorFrameEffects {
        var result = MonitorFrameEffects()
        result.peaking = isVisible(.peaking)
        result.zebra = isVisible(.zebra) && offers(.zebra)
        result.falseColor = isVisible(.falseColor) && offers(.falseColor)
        result.histogram = showsScopes(.histogram)
        result.waveform = showsScopes(.waveform)
        result.parade = showsScopes(.parade)
        result.vectorscope = showsScopes(.vectorscope)
        result.trafficLights = showsScopes(.trafficLights)
        result.ndMeter = showsScopes(.ndMeter)
        result.lutDimension = isVisible(.lut) ? lutDimension : 0
        result.lutRGBA = isVisible(.lut) ? lutRGBA : Data()
        result.peakingColor = peakingColor
        result.peakingSensitivity = peakingSensitivity
        result.falseColorScale = falseColorScale
        result.falseColorRec709 = falseColorRec709
        result.zebraHighlight = zebraHighlight
        result.zebraMidtone = zebraMidtone
        result.zebraHighlightIRE = zebraHighlightIRE
        result.zebraMidtoneIRE = zebraMidtoneIRE
        result.zebraHighlightColor = zebraHighlightColor
        result.zebraMidtoneColor = zebraMidtoneColor
        result.transfer = looks.transfer
        result.referenceClipByte = looks.referenceClipByte
        result.allowsTransferInference = allowsTransferInference
        result.splitComparison = splitComparison && isVisible(.lut)
        result.splitVertical = splitVertical
        result.mirror = mirrorsHorizontally
        result.mirrorVertical = flipsVertically
        result.desqueezeFactor = isVisible(.desqueeze) ? desqueezeFactor : 1
        result.desqueezeHorizontal = desqueezeHorizontal
        result.trafficThreshold = crushClipCompensation.pixelFractionThreshold
        return result
        .withEVMeter(evMeterFromPicture && isVisible(.evMeter))
        .withInspectorDemand(inspectorSceneActive && !gradesClip ? configureTool : nil)
    }

    public var playbackEffects: MonitorFrameEffects {
        var fx = effects
        fx.allowsTransferInference = true
        fx.inspectorSample = false
        fx.peaking = isPlaybackVisible(.peaking)
        fx.zebra = isPlaybackVisible(.zebra)
        fx.falseColor = isPlaybackVisible(.falseColor)
        fx.histogram = isPlaybackVisible(.histogram)
        fx.waveform = isPlaybackVisible(.waveform)
        fx.parade = isPlaybackVisible(.parade)
        fx.vectorscope = isPlaybackVisible(.vectorscope)
        fx.trafficLights = isPlaybackVisible(.trafficLights)
        fx.ndMeter = isPlaybackVisible(.ndMeter)
        fx.evMeter = false
        fx.lutDimension = isPlaybackVisible(.lut) ? lutDimension : 0
        fx.lutRGBA = isPlaybackVisible(.lut) ? lutRGBA : Data()
        fx.splitComparison = splitComparison && isPlaybackVisible(.lut)
        fx.mirror = isPlaybackVisible(.mirror) && mirrorHorizontal
        fx.mirrorVertical = isPlaybackVisible(.mirror) && mirrorVertical
        fx.desqueezeFactor = isPlaybackVisible(.desqueeze) ? desqueezeFactor : 1
        return fx.withInspectorDemand(inspectorSceneActive && gradesClip ? configureTool : nil)
    }

    /// Cheap inspector options without preparing a preview-only LUT. The caller captures
    /// its source transfer and sampling-time ceiling before the worker admits this job.
    public func inspectorImageOptions(tool: MonitorAssistSelection,
        transfer: MonitorTransfer, clipByte: Int) -> MonitorFrameEffects {
        var result = gradesClip ? playbackEffects : effects
        result.peaking = tool == .peaking
        result.falseColor = tool == .falseColor
        result.zebra = tool == .zebra
        result.histogram = false
        result.waveform = false
        result.parade = false
        result.vectorscope = false
        result.trafficLights = false
        result.ndMeter = false
        result.faceAF = false
        result.inspectorSample = false
        result.transfer = transfer
        result.clipByte = clipByte
        result.mirror = (tool == .mirror && mirrorHorizontal) || result.mirror
        result.mirrorVertical = (tool == .mirror && mirrorVertical) || result.mirrorVertical
        if tool == .lut { result.splitComparison = splitComparison }
        if tool == .desqueeze { result.desqueezeFactor = desqueezeFactor }
        return result
    }

    /// Forces this inspector's selected image assist without changing the main picture.
    /// LUT preparation occurs only when the retained native worker admits a job.
    public func inspectorImageEffects(tool: MonitorAssistSelection,
        transfer: MonitorTransfer, clipByte: Int) -> MonitorFrameEffects {
        var result = inspectorImageOptions(tool: tool, transfer: transfer, clipByte: clipByte)
        if tool == .lut {
            let lut = inspectorLUT(transfer: transfer)
            result.lutDimension = lut.dimension
            result.lutRGBA = lut.rgba
        }
        return result
    }

    public let looks: Looks
    @ObservationIgnored private let storage: UserDefaults
    @ObservationIgnored private let keys: MonitorAssistPreferenceKeys
    @ObservationIgnored private let onToggle: (@MainActor (MonitorAssistSelection, Bool) -> Void)?
    @ObservationIgnored private let cleanPinCases: [MonitorAssistSelection]
    /// What a fresh state and each Reset land on.
    public let defaults: MonitorAssistDefaults

    /// Explicit toggle side effect after mutation: live before persistence, playback after.
    /// Direct assignments and visibility changes do not invoke this callback.
    public init(looks: Looks, storage: UserDefaults, keys: MonitorAssistPreferenceKeys,
        cleanPinCases: [MonitorAssistSelection], defaults: MonitorAssistDefaults = .standard,
        onToggle: (@MainActor (MonitorAssistSelection, Bool) -> Void)? = nil
    ) {
        self.onToggle = onToggle
        self.looks = looks; self.storage = storage; self.keys = keys; self.cleanPinCases = cleanPinCases
        self.defaults = defaults
        zebraHighlightIRE = defaults.zebraHighlightIRE
        crushClipCompensation = defaults.crushClipCompensation
        if let data = storage.data(forKey: keys.assist),
            let snapshot = try? JSONDecoder().decode(MonitorAssistSnapshot.self, from: data) {
            snapshot.apply(to: self)
        }
        if let raw = storage.array(forKey: keys.cleanPins) as? [String] {
            cleanViewPinnedTools = Set(raw.compactMap(MonitorAssistSelection.init(rawValue:))).intersection(cleanPinCases)
        }
        if let raw = storage.array(forKey: keys.playback) as? [String] {
            playbackVisibleTools = Set(raw.compactMap(MonitorAssistSelection.init(rawValue:)))
        }
        if lutEnabled { refreshLUTCube() }
        lastSaved = encodedSnapshot()
    }

    /// Picture corrections stay visible in DISP 2 unless the operator unpins them.
    nonisolated public static var cleanViewDefaultPinnedTools: Set<MonitorAssistSelection> { [.lut, .peaking, .desqueeze, .mirror] }

    public func isOn(_ tool: MonitorAssistSelection) -> Bool {
        switch tool {
        case .lut: lutArmed
        case .peaking: peaking
        case .zebra: zebra
        case .falseColor: falseColor
        case .waveform: waveform
        case .parade: parade
        case .histogram: histogram
        case .vectorscope: vectorscope
        case .trafficLights: trafficLights
        case .ndMeter: ndMeter
        case .evMeter: evMeter
        case .audioMeters: audioMeters
        case .guides: guides
        case .grid: grid
        case .crosshair: crosshair
        case .level: level
        case .desqueeze: desqueeze
        case .mirror: mirror
        case .instantReview: instantReview
        case .magnification: false
        default: false
        }
    }

    public func isVisible(_ tool: MonitorAssistSelection) -> Bool {
        guard isOn(tool) else { return false }
        if clean { return tool != .evMeter && cleanViewPinnedTools.contains(tool) }
        return true
    }

    /// Live picture flips as shown. The tool on with an axis off leaves that axis alone.
    public var mirrorsHorizontally: Bool { isVisible(.mirror) && mirrorHorizontal }
    public var flipsVertically: Bool { isVisible(.mirror) && mirrorVertical }

    public func toggleCleanViewPin(_ tool: MonitorAssistSelection) {
        guard cleanPinCases.contains(tool) else { return }
        var pins = cleanViewPinnedTools
        if pins.contains(tool) {
            pins.remove(tool)
        } else {
            pins.insert(tool)
        }
        cleanViewPinnedTools = pins
        storage.set(cleanPinCases.filter { pins.contains($0) }.map(\.rawValue), forKey: keys.cleanPins)
    }

    public func isPlaybackVisible(_ tool: MonitorAssistSelection) -> Bool {
        tool != .evMeter && playbackVisibleTools.contains(tool)
    }

    public func togglePlayback(_ tool: MonitorAssistSelection) {
        guard tool != .evMeter else { return }
        if playbackVisibleTools.contains(tool) {
            playbackVisibleTools.remove(tool)
        } else {
            playbackVisibleTools.insert(tool)
        }
        storage.set(playbackVisibleTools.map(\.rawValue).sorted(), forKey: keys.playback)
        onToggle?(tool, isPlaybackVisible(tool))

    }

    public func toggle(_ tool: MonitorAssistSelection) {
        switch tool {
        case .lut:
            if lutEnabled {
                lutEnabled = false
                refreshLUTCube()
            } else {
                armLastLUT()
            }
        case .peaking: peaking.toggle()
        case .zebra: zebra.toggle()
        case .falseColor:
            falseColor.toggle()

        case .waveform: waveform.toggle()
        case .parade: parade.toggle()
        case .histogram: histogram.toggle()
        case .vectorscope: vectorscope.toggle()
        case .trafficLights: trafficLights.toggle()
        case .ndMeter: ndMeter.toggle()
        case .evMeter: evMeter.toggle()
        case .audioMeters: audioMeters.toggle()
        case .guides:
            guides.toggle()
            if guides, selectedGuides.isEmpty { selectedGuides = [guideAspect] }
        case .grid: grid.toggle()
        case .crosshair: crosshair.toggle()
        case .level: level.toggle()
        case .desqueeze: desqueeze.toggle()
        case .mirror: mirror.toggle()
        case .instantReview: instantReview.toggle()
        case .magnification: break
        default: break
        }
        onToggle?(tool, isOn(tool))
        persist()
    }

    public func armLastLUT() {
        lutEnabled = true
        refreshLUTCube()
        persist()
    }
    public func nudgeLUTExposure(_ delta: Double) {
        let next = LUTExposureCompensation.stepped(lutExposureStops, by: delta)
        guard next != lutExposureStops else { return }
        lutExposureStops = next
        refreshLUTCube()
        persist()
    }
    public func refreshLUTCube() {
        inspectorLUTCache = nil
        guard lutEnabled, let cube = looks.cube else {
            lutCube = nil
            lutDimension = 0
            lutRGBA = Data()
            return
        }
        cache(cube)
    }

    public func inspectorLUT(transfer: MonitorTransfer) -> (dimension: Int, rgba: Data) {
        if let cached = inspectorLUTCache,
            cached.selection == looks.selection, cached.transfer == transfer,
            cached.stops == appliedLUTExposureStops
        {
            return (cached.dimension, cached.rgba)
        }
        guard let cube = looks.cube else { return (0, Data()) }
        let gpu = cube.colorCube.compensatingExposure(
            stops: appliedLUTExposureStops, transfer: looks.lutExposureTransfer(for: transfer))
        let rgba = gpu.rgbaComponents.withUnsafeBytes { Data($0) }
        inspectorLUTCache = InspectorLUTCache(
            selection: looks.selection, stops: appliedLUTExposureStops, transfer: transfer,
            dimension: gpu.size, rgba: rgba)
        return (gpu.size, rgba)
    }

    private struct InspectorLUTCache {
        var selection: Looks.Selection
        var stops: Double
        var transfer: MonitorTransfer
        var dimension: Int
        var rgba: Data
    }

    public func cycleGuide() {
        let all = MonitorGuideAspect.ratios(for: guideFamily)
        guard let idx = all.firstIndex(of: guideAspect) else {
            guideAspect = all.first ?? .cinema
            selectedGuides = [guideAspect]
            guides = true
            persist()
            return
        }
        guideAspect = all[(idx + 1) % all.count]
        selectedGuides = [guideAspect]
        guides = true
        persist()
    }

    public func toggleGuide(_ aspect: MonitorGuideAspect) {
        if selectedGuides.contains(aspect) {
            selectedGuides.remove(aspect)
        } else {
            selectedGuides.insert(aspect)
        }
        guideAspect = aspect
        guides = !selectedGuides.isEmpty
        persist()
    }

    public func persist() {
        persistIfNeeded(force: true)
    }

    private func persistIfNeeded(force: Bool = false) {
        let data = encodedSnapshot()
        if !force, data == lastSaved { return }
        lastSaved = data
        if let data { storage.set(data, forKey: keys.assist) }
    }

    public func encodedSnapshot() -> Data? { try? JSONEncoder().encode(MonitorAssistSnapshot(self)) }

    /// A caller that names the clip's curve bakes on it; otherwise the source's curve, and no input
    /// exposure while that is unknown.
    public func exportCube(bakeExposure: Bool, transfer: MonitorTransfer? = nil) -> CubeLUT? {
        guard lutEnabled, let cube = lutCube else { return nil }
        let stops = transfer != nil || sourceCurveKnown ? lutExposureStops : 0
        return cube.preparedForExport(bakeExposure: bakeExposure, stops: stops,
            transfer: looks.lutExposureTransfer(for: transfer ?? looks.transfer))
    }

    private func cache(_ cube: CubeLUT) {
        lutCube = cube
        let transfer = looks.transfer
        let gpu = cube.colorCube.compensatingExposure(
            stops: appliedLUTExposureStops, transfer: looks.lutExposureTransfer(for: transfer))
        lutDimension = gpu.size
        lutRGBA = gpu.rgbaComponents.withUnsafeBytes { Data($0) }
    }
}
