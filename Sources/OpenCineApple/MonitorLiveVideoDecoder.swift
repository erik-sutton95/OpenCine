#if canImport(UIKit) && canImport(CoreImage) && canImport(VideoToolbox)
import CoreImage
import CoreVideo
import Foundation
import OpenCineMedia

/// Source effects, publication and optional simulator input over one retained native decoder.
/// Apps supply source interpretation, diagnostics and footage selection as typed values.
@MainActor
open class MonitorLiveVideoDecoder: MonitorLiveVideoRuntime {
    public var effects = MonitorFrameEffects() {
        didSet { syncDemand() }
    }
    public var needsWatchPreview: Bool {
        get { demand.externalPreview }
        set {
            guard demand.externalPreview != newValue else { return }
            demand.externalPreview = newValue
        }
    }
    public var onWatchPreview: ((CIImage, CVPixelBuffer?, Bool) -> Void)? {
        get { onPreviewFrame }
        set { onPreviewFrame = newValue }
    }
    /// Installed once by the actual source owner, never by a borrowed editor.
    /// Read only when binding/reopening a source or after a camera report.
    public var sourceCalibrationProvider: (() -> Int?)?
    public var effectsProvider: (() -> MonitorFrameEffects)? {
        didSet {
            demandProvider = { [weak self] in
                guard let self else { return .init() }
                if let next = self.effectsProvider?(), next != self.effects { self.effects = next }
                return self.demand
            }
        }
    }
    public var backdropEffects: MonitorFrameEffects {
        var result = effects
        let native = backdropPolicy.image
        result.clipByte = native.clipByte
        result.mirror = presentedPictureFlip ?? pictureFlip
        result.lutDimension = native.lutDimension
        result.lutRGBA = native.lutRGBA
        result.peaking = native.peaking
        result.zebra = native.zebra
        result.falseColor = native.falseColor
        result.desqueezeFactor = native.desqueezeFactor
        return result
    }

    private let simulatorConfiguration: MonitorSimulatorVideoConfiguration?
    #if targetEnvironment(simulator)
        private let simulatorFeed: MonitorSimulatorVideoFeed?
    #endif

    public init(configuration: MonitorVideoConfiguration = .init(),
        simulator: MonitorSimulatorVideoConfiguration? = nil) {
        simulatorConfiguration = simulator
        #if targetEnvironment(simulator)
            simulatorFeed = simulator.map { MonitorSimulatorVideoFeed(configuration: $0) }
        #endif
        super.init(configuration: configuration)
    }

    private func syncDemand() {
        demand = .init(
            assists: effects.nativeAssistPolicy,
            decodedSource: effects.faceAF || effects.inspectorSample,
            externalPreview: demand.externalPreview)
    }

    public func attach(
        sampleBus: LiveFrameSampleBus, effects provider: @escaping () -> MonitorFrameEffects,
        transfer: @escaping () -> MonitorTransfer? = { nil }
    ) {
        bindSourcePublication(sampleBus)
        self.effectsProvider = provider
        transferProvider = transfer
        effects = provider()
        adoptIncomingTransfer(transfer())
    }

    public func bindSourcePublication(_ bus: LiveFrameSampleBus) {
        sampleBus = bus
        refreshSourceCalibration()
    }

    @discardableResult
    public func refreshSourceCalibration() -> Bool {
        let source = sourceToken
        let iso = sourceCalibrationProvider?()
        return updateSourceCalibration(iso: iso, source: source)
    }

    @discardableResult
    public func decode(accessUnit: [UInt8]) -> Bool {
        super.decode(accessUnit: accessUnit, source: sourceToken)
    }

    public nonisolated func handleDecodedFrame(
        _ buffer: CVPixelBuffer, effects: MonitorFrameEffects? = nil,
        transfer: MonitorTransfer? = nil, isNewSourceFrame: Bool = true, generation: Int? = nil,
        timeNs: Int64 = 0, source: MonitorVideoSourceToken? = nil
    ) {
        super.submitDecodedFrame(
            buffer, policy: effects?.nativeAssistPolicy,
            transfer: transfer, isNewSourceFrame: isNewSourceFrame, generation: generation,
            timeNs: timeNs, source: source)
    }

    public nonisolated func handleDecodedFrame(
        _ lease: DecodedFrameLease, effects: MonitorFrameEffects? = nil,
        transfer: MonitorTransfer? = nil, isNewSourceFrame: Bool = true,
        source: MonitorVideoSourceToken? = nil
    ) {
        super.submitDecodedFrame(
            lease, policy: effects?.nativeAssistPolicy,
            transfer: transfer, isNewSourceFrame: isNewSourceFrame, source: source)
    }

    open override func close() {
        stopSimulatorSample()
        super.close()
        effectsProvider = nil
        sourceCalibrationProvider = nil
    }

    open override func reset() {
        stopSimulatorSample()
        super.reset()
        refreshSourceCalibration()
        startSimulatorSampleIfNeeded()
    }

    /// Simulator footage is an app-selected source, admitted with the token captured at start.
    open func startSimulatorSampleIfNeeded() {
        #if targetEnvironment(simulator)
            guard let source = sourceToken, let configuration = simulatorConfiguration,
                let simulatorFeed else { return }
            preparePixelBufferSource(transfer: configuration.transfer)
            simulatorFeed.start { [weak self] buffer in
                self?.handleDecodedFrame(buffer, transfer: configuration.transfer, source: source)
            }
        #endif
    }

    public func stopSimulatorSample() {
        #if targetEnvironment(simulator)
            simulatorFeed?.stop()
        #endif
    }
}

#endif
