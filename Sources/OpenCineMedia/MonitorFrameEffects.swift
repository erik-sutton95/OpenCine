import Foundation

/// Source-qualified picture, sampling and display demand. No camera setting is retained here.
public struct MonitorFrameEffects: Equatable, Sendable {
    public init() {}
    public var peaking = false
    public var zebra = false
    public var falseColor = false
    public var histogram = false
    public var waveform = false
    public var parade = false
    public var vectorscope = false
    public var trafficLights = false
    public var ndMeter = false
    /// EV meter reading the picture: the scope tap must run.
    public var evMeter = false
    public var lutDimension = 0
    public var lutRGBA = Data()

    public var peakingColor: MonitorPeakingColor = .red
    public var peakingSensitivity: MonitorPeakingSense = .medium
    public var falseColorScale: MonitorFalseColorSelection = .sceneStops
    /// Read: 709 (official Rec.709 look) or LOG (signal). Part of the effects so a
    /// change re-renders and rebakes the overlay.
    public var falseColorRec709 = false
    public var zebraHighlight = true
    public var zebraMidtone = true
    public var zebraHighlightIRE: Double = LiveZebra.highlightIRE
    public var zebraMidtoneIRE: Double = LiveZebra.midtoneIRE
    public var zebraHighlightColor: MonitorZebraPaint = .white
    public var zebraMidtoneColor: MonitorZebraPaint = .amber
    /// The source adapter supplies its published transfer curve.
    public var transfer = MonitorTransfer.rec709
    /// Sampling-time source ceiling; nil retains the source adapter's reference value.
    public var clipByte: Int?
    public var referenceClipByte = 255
    /// Photo has an authoritative Rec.709 source; scene brightness cannot identify log.
    public var allowsTransferInference = true
    public var splitComparison = false
    public var splitVertical = true
    /// Left-to-right monitor flip. Applied in `VideoView`, not this compositor.
    public var mirror = false
    /// Top-to-bottom monitor flip (MIRROR Vertical). Same view-space path as `mirror`.
    public var mirrorVertical = false
    /// Anamorphic display stretch. `1` is off. Anamorphic adapters squeeze the source;
    /// this preview-only correction never changes recordings or scope samples.
    public var desqueezeFactor: Double = 1
    public var desqueezeHorizontal = true
    /// Traffic-light pixel-fraction threshold (operator compensation, stops / 10).
    public var trafficThreshold: Double = ScopeTrafficLights.defaultThreshold
    /// AF-C face box. Starts VT so Vision can see a `CVPixelBuffer`.
    public var faceAF = false
    /// An open inspector requests the existing decoded-source tap. It never
    /// enables a main-picture effect or an additional decoder/display sink.
    public var inspectorSample = false

    /// Peaking / false colour / zebra / LUT / display transforms; painted on the video frame.
    public var needsGPUFeed: Bool {
        peaking || zebra || falseColor
            || lutDimension >= 2 || desqueezeFactor > 1.001
    }

    /// LUT / de-squeeze remake every pixel. Zebra, peaking, and false colour
    /// only paint; the identity HEVC / VT layer stays so contrast does not
    /// shift. A DeviceRGB bake of the Rec.709 picture is a visible
    /// Rec.709→sRGB re-encode. 50/50 is a LUT option, not its own replace
    /// path; split without a cube covered HEVC with an empty Metal plate.
    public var replacesIdentityFeed: Bool {
        lutDimension >= 2
            || desqueezeFactor > 1.001
    }

    /// GPU 50/50 log-vs-LUT. Same gate as Android `FeedEffectsRenderPlan`.
    public var appliesSplitComparison: Bool {
        FeedPresentPolicy.appliesSplitComparison(
            enabled: splitComparison,
            hasLUTCube: lutDimension >= 2 && !lutRGBA.isEmpty,
            falseColorPaintsFullFrame: falseColor && falseColorScale != .limits)
    }

    /// Transparent stripe / peaking overlay on top of the identity layer.
    public var needsOverlayFeed: Bool {
        needsGPUFeed && !replacesIdentityFeed
    }

    /// Clip byte zebra and FALSE use for the source curve.
    public var resolvedClipByte: Int {
        clipByte ?? referenceClipByte
    }

    /// Stamp the source's curve and its live ceiling together.
    public mutating func stamp(transfer: MonitorTransfer, ceiling: OpenCineMedia.ScopeExposureCeiling) {
        self.transfer = transfer
        clipByte = ceiling.clipByte(transfer: transfer)
    }

    /// WAVE / PARADE / HISTO / VECTOR / LIGHTS / ND share the source tap.
    public var needsScopes: Bool {
        histogram || waveform || parade || vectorscope || trafficLights || ndMeter || evMeter
    }

    public var needsScopePoints: Bool {
        waveform || parade || vectorscope
    }

    public var activeScopeCount: Int {
        [histogram, waveform, parade, vectorscope, trafficLights, ndMeter].filter { $0 }
            .count
    }

    /// GPU feed, CPU scopes, or AF-C face detect. Any one starts VT for a pixel buffer.
    public var needsSample: Bool {
        needsGPUFeed || needsScopes || faceAF || inspectorSample
    }

    public var needsProcessedFeed: Bool { needsSample }

    public func withEVMeter(_ on: Bool) -> MonitorFrameEffects {
        var fx = self
        fx.evMeter = on
        return fx
    }

    public func withFaceAF(_ on: Bool) -> MonitorFrameEffects {
        var fx = self
        fx.faceAF = on
        return fx
    }
}

public enum MonitorFalseColorSelection: String, CaseIterable, Codable, Sendable {
    case sceneStops = "SceneStops"
    case stops = "CineStop"
    case ire = "IRE"
    case limits = "Limits"
}


extension MonitorFalseColorSelection {
    public var liveScale: LiveFalseColorScale {
        switch self {
        case .sceneStops: .sceneStops
        case .stops: .stops
        case .ire: .ire
        case .limits: .limits
        }
    }

}

public enum MonitorInspectorImageSizing {
    public static let maximumDimension: Double = 320
}
