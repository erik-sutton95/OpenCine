#if canImport(CoreImage)
import Foundation
import OpenCineMedia

/// Source facts and optional source interpretation. The native owner has no camera protocol.
public struct MonitorAssistConfiguration: Sendable {
    public var clipProfile: ScopeClipProfile
    public var lookCurves: [MonitorTransfer: [Double]]
    public var defaultScopeLook: @Sendable (MonitorTransfer) -> CubeLUT?
    public var inferTransfer: (@Sendable (UInt8, UInt8, MonitorTransfer) -> MonitorTransfer)?
    public var logSubsystem: String
    public var journal: @Sendable (String) -> Void
    public init(clipProfile: ScopeClipProfile = .init(),
        lookCurves: [MonitorTransfer: [Double]] = [:],
        defaultScopeLook: @escaping @Sendable (MonitorTransfer) -> CubeLUT? = { _ in nil },
        inferTransfer: (@Sendable (UInt8, UInt8, MonitorTransfer) -> MonitorTransfer)? = nil,
        logSubsystem: String = "com.opencapture.opencine", journal: @escaping @Sendable (String) -> Void = { _ in }) {
        self.clipProfile = clipProfile; self.lookCurves = lookCurves
        self.defaultScopeLook = defaultScopeLook; self.inferTransfer = inferTransfer
        self.logSubsystem = logSubsystem; self.journal = journal
    }
}

/// Immutable policy shared by the image and scope paths of one native owner.
public struct MonitorAssistPolicy: Equatable, Sendable {
    public var image = MonitorImageEffects()
    public var histogram = false
    public var waveform = false
    public var parade = false
    public var vectorscope = false
    public var trafficLights = false
    public var ndMeter = false
    public var evMeter = false
    public var trafficThreshold = ScopeTrafficLights.defaultThreshold
    public var allowsTransferInference = false
    public var falseColorScale = LiveFalseColorScale.sceneStops
    public var falseColorRec709 = false
    public init() {}
    public var needsGPUFeed: Bool {
        image.peaking || image.zebra || image.falseColor
            || image.lutDimension >= 2 || image.desqueezeFactor > 1.001
    }
    public var replacesIdentityFeed: Bool {
        image.lutDimension >= 2 || image.desqueezeFactor > 1.001
    }
    public var needsOverlayFeed: Bool {
        needsGPUFeed && image.lutDimension < 2 && image.desqueezeFactor <= 1.001
    }
    public var needsScopes: Bool {
        histogram || waveform || parade || vectorscope || trafficLights || ndMeter || evMeter
    }
    public var activeScopeCount: Int {
        [histogram, waveform, parade, vectorscope, trafficLights, ndMeter].filter { $0 }.count
    }
    public var resolvedClipByte: Int { image.clipByte }
    public mutating func stamp(transfer: MonitorTransfer, ceiling: ScopeExposureCeiling) {
        image.transfer = transfer
        image.clipByte = ceiling.clipByte(transfer: transfer)
        image.peakingGateScale = Peaking.gateScale(for: transfer)
    }
}
#endif
