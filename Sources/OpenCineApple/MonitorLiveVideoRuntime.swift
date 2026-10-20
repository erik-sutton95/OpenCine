#if canImport(UIKit) && canImport(CoreImage) && canImport(VideoToolbox)
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import OpenCineCore
import OpenCineMedia
import QuartzCore
import VideoToolbox
import os

/// Owns encoded-source admission, one native decoder, source-pixel demand and retained presentation.
/// Recovery signals are actions for the source owner; this runtime never sends camera commands.
@MainActor
open class MonitorLiveVideoRuntime {
    /// One retained decode owner, used by both layer identity and native assist presentation.
    private let vt: VideoToolboxDecoder
    /// Native submission boundary for deterministic SIMULATED submit-return failures.
    internal typealias NativeSubmission = @MainActor (
        VideoToolboxDecoder, CMSampleBuffer, VTDecodeFrameFlags, StreamGeneration,
        @escaping @Sendable (VideoToolboxDecoder.Output) -> Void
    ) -> OSStatus
    internal var nativeSubmission: NativeSubmission?
    private let configuration: MonitorVideoConfiguration
    nonisolated private let sourceLifetime: OSAllocatedUnfairLock<MonitorVideoSourceLifetime>
    /// Lives as long as this decoder: host views adopt it, they never recreate it.
    public var displayLayer: AVSampleBufferDisplayLayer { vt.displayLayer }
    public var hasFormat: Bool { vt.format != nil }
    private var hasSubmittedRandomAccess = false
    public private(set) var nalTypesSeen: Set<Int> = []
    public var decoderErrors: Int { vt.decoderErrors }
    /// Last VT / layer decode failure. `decoderErrors` is cumulative: one bad
    /// AU an hour ago must not read as `decoderWedged` on the observe line.
    public var lastDecodeErrorAt: Date? { vt.lastDecodeErrorAt }
    public var lastDecodeStatus: Int32 { vt.lastDecodeStatus }
    public var lastDecodeOrigin: String { vt.lastDecodeOrigin }
    public var lastDecodeFlags: UInt32 { vt.lastDecodeFlags }

    public var nativeOutputAge: TimeInterval? { pipelineMetrics.outputAge }
    public var incidentDecodeSnapshot: MonitorDecodeMetrics.Snapshot { pipelineMetrics.snapshot }
    public private(set) var sourcePresentations = 0
    public var incidentPresentations: Int {
        if effects.replacesIdentityFeed, let feed = ownedProcessedFeed { return feed.presentedFrames }
        return sourcePresentations
    }
    public var nativeOutputExpected: Bool {
        accepts(sourceToken) && (shouldStartVT || referenceRecoveryNeeded)
    }
    public private(set) var referenceRecoveryNeeded = false
    /// Last accepted IRAP. Tells the source recovery policy an enable was already answered.
    public private(set) var lastIrapAt: Date?
    /// VT submission order. A late failure callback for a picture submitted before the last
    /// accepted IRAP describes references that IRAP already replaced.
    private var submissionSequence: UInt64 = 0
    private var lastIrapSubmission: UInt64 = 0
    /// Bitstream facts behind the first VT error since the last native output. Later errors of
    /// the same episode keep it; the next episode replaces it. Incident context only.
    public private(set) var firstDecodeError: FeedIncidentDecodeErrorContext?
    private var outputsAtLastError: Int?
    /// Access units admitted in the last second, for the incident input rate.
    private var recentInputUptimes: [TimeInterval] = []
    private var lastParameterSetChangeUptime: TimeInterval?
    public var nativeDecodeTotals: (submitted: Int, accepted: Int, output: Int) { pipelineMetrics.totals }
    public var canReleaseIDRHold: Bool { hasSubmittedRandomAccess && !vt.sessionFailed }

    public private(set) var lastKeyframeAt: Date?
    /// Last AU enqueued or VT frame presented. Source stall signal (not keyframe age).
    public private(set) var lastPresentedAt: Date?
    /// New source pictures only; cached LUT/layout redraws never advance this.
    public private(set) var lastSourceFrameAt: Date?
    /// True after `flushAndRemoveImage` until a replacement sample is presented.
    public private(set) var displayedImageRemoved = false
    /// GOP-reset recover: drop P-frames until the next IDR so the layer cannot fail to black.
    public private(set) var awaitingIDR = false
    public private(set) var sawKeyframe = false
    /// Assist rendering and actual source-pixel consumers share one decoder.
    public var demand = MonitorVideoDemand() {
        didSet { applyEffectsChange() }
    }
    private var effects: MonitorAssistPolicy { demand.assists }
    private var needsDecodedSample: Bool { demand.needsDecodedSample }
    /// Last accepted source transfer. Provider wins when set.
    public var incomingTransfer: MonitorTransfer? {
        didSet { syncAssistPolicy() }
    }
    /// Missing source status does not erase a previously accepted transfer.
    public func adoptIncomingTransfer(_ next: MonitorTransfer?) {
        if let next { incomingTransfer = next }
    }
    /// Read on every access unit so PEAK/LUT do not depend on SwiftUI `onChange`.
    public var demandProvider: (() -> MonitorVideoDemand)?
    public var transferProvider: (() -> MonitorTransfer?)?
    private var pictureOwnership: MonitorPictureHost.Ownership?
    private var ownedProcessedFeed: MonitorPictureHost? {
        guard let processedFeed, processedFeed.owns(pictureOwnership) else { return nil }
        return processedFeed
    }
    public weak var processedFeed: MonitorPictureHost? {
        didSet {
            guard processedFeed !== oldValue else { return }
            oldValue?.releaseOwnership(pictureOwnership)
            pictureOwnership = nil
            guard accepts(sourceToken), let processedFeed else { return }
            let ownership = processedFeed.claimOwnership()
            pictureOwnership = ownership
            processedFeed.onPresented = { [weak self] in
                Task { @MainActor in
                    guard let self, self.sourceToken != nil,
                        self.pictureOwnership === ownership else { return }
                    self.adoptPresentedFeed()
                }
            }
            guard let buffer = lastDecodedBuffer, effects.needsGPUFeed else { return }
            submitDecodedFrame(buffer, isNewSourceFrame: false, timeNs: lastDecodedTimeNs)
        }
    }
    nonisolated private let samplePublication = OSAllocatedUnfairLock<LiveFrameSampleBus.Source?>(initialState: nil)
    private var sampleSource: LiveFrameSampleBus.Source? {
        get { samplePublication.withLock { $0 } }
        set { samplePublication.withLock { $0 = newValue } }
    }
    public weak var sampleBus: LiveFrameSampleBus? {
        didSet {
            guard sourceToken != nil else {
                oldValue?.closeSource(sampleSource)
                sampleSource = nil
                return
            }
            if sampleBus !== oldValue {
                oldValue?.closeSource(sampleSource)
                sampleSource = sampleBus?.openSource(.live)
            }
            // Calibration history belongs to the same lease as publication.
            if let sampleSource { assistEngine.adopt(exposureCeiling: sampleSource.exposureCeiling) }
            if shouldStartVT, vt.session == nil, vt.format != nil { rebuildVT() }
        }
    }
    /// Fired on the main actor after a picture is presented (live VT, layer enqueue, or simulator).
    public var onSourceAdvanced: (() -> Void)?
    public var onPresentedFrame: (() -> Void)?
    /// VT source buffer after assist present, lent to source-pixel consumers. The lease is lent for the call
    /// and released when it returns; keep `pixelBuffer` to use the pixels later.
    public var onSourceFrame: ((DecodedFrameLease) -> Void)?
    /// External preview. `source` is the VT identity buffer when a cube does not own
    /// the picture (`nil` for LUT replace). `unmanaged` is a cube product.
    public var onPreviewFrame: ((CIImage, CVPixelBuffer?, Bool) -> Void)?
    /// Decoded identity buffer before LUT/PEAK. External identity encode tap.
    nonisolated(unsafe) public var onIdentityFrame: ((CVPixelBuffer) -> Void)?
    /// View-space X flip applied on the host view at present time (not SwiftUI).
    public var poseViewFlip = false
    public var assistMirror = false
    /// The picture host commits mirror in the same tick as enqueue.
    public var applyPictureMirror: ((Bool) -> Void)?
    /// Relay metadata follows the actual flip commit, independently of the 5 Hz HUD.
    public var onIdentityOrientation: ((Bool) -> Void)?
    public private(set) var presentedPictureFlip: Bool? {
        didSet {
            if presentedPictureFlip != oldValue {
                onIdentityOrientation?(presentedPictureFlip ?? false)
            }
        }
    }
    /// Holds the last picture across extra-mirror so the current frame is not X-flipped in place.
    private var extraMirrorHold = ExtraMirrorHold()
    /// First time VT takes HEVC this session. Mid-GOP P-frames cannot start a
    /// new decoder  -  one `random-access request`. Later assist toggles must not fire this.
    public var onHandoffNeedsIDR: (() -> Void)?
    /// Source orientation / vertical mode restarts the encoder. Request a new GOP
    /// only when this AU did not already carry the IDR.
    public var onParameterSetsChanged: (() -> Void)?
    /// The decoder is not observable; the session republishes the raster so the
    /// layout re-fits when the camera flips between horizontal and vertical.
    public var onPictureSizeChanged: (() -> Void)?
    /// Set when SPS/PPS change mid-session; consumed after the rest of the AU is parsed.
    private var pendingParameterChangeEnable = false
    /// Last accepted format dimensions. `0` until the first parameter sets land.
    public private(set) var pictureSize: CGSize = .zero
    /// Survives encoder rebuilds (screen flip zeros `pictureSize` until the new SPS).
    public private(set) var isVerticalPicture = false
    public var pictureAspect: CGFloat {
        FeedRaster.aspect(
            width: Int(pictureSize.width), height: Int(pictureSize.height),
            fallback: isVerticalPicture ? 9.0 / 16.0 : 16.0 / 9.0)
    }

    /// Latched from the first parameter-set AU. HEVC or AVC.
    private var liveCodec: LiveVideoCodec?
    public var incidentCodec: String { liveCodec.map { $0 == .avc ? "avc" : "hevc" } ?? "unknown" }
    private var vps: [UInt8]?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    /// Capture before asynchronous decode; returned pixels must retain this token
    /// through assist work and its eventual MainActor completion.
    nonisolated public var sourceFrameGeneration: Int {
        Int(truncatingIfNeeded: vt.fence.generation.value)
    }
    private var displayReadyCont: CheckedContinuation<Bool, Never>?
    nonisolated private let assistEngine: MonitorAssistEngine
    nonisolated private let pipelineMetrics = MonitorDecodeMetrics()
    private let log: Logger
    /// Simulator (and any pixel-buffer-only source) paints identity on `MonitorPictureHost`.
    private var prefersPixelBufferDisplay = false
    /// Fast / Quality / AI must present through Metal. Off keeps the identity HEVC layer.
    public var feedUpscaler: MonitorUpscaler = .off {
        didSet {
            guard oldValue != feedUpscaler else { return }
            applyEffectsChange()
        }
    }
    /// Outdoor HDR panel. Identity presents through Metal EDR; VT stays sticky.
    public var hdrDisplayEnabled = false {
        didSet {
            guard oldValue != hdrDisplayEnabled else { return }
            #if !targetEnvironment(simulator)
                prefersPixelBufferDisplay = hdrDisplayEnabled
            #endif
            applyEffectsChange()
        }
    }
    /// VT owns the HEVC block; the display layer only shows already-decoded image buffers.
    private var vtOwnsHardwareDecode = false

    /// WAVE/HISTO/PEAK need a `CVPixelBuffer`. Do not also start VT just because
    /// `sampleBus` is attached  -  that dual-decoded 4K60 HEVC with the display layer
    /// and starved `submitDecodedFrame` on device after `5234802`.
    /// Sticky after the first assist: tearing VT to hand HEVC back is a GOP reset.
    private var sessionOwnsVT = false
    /// Format + `effects.needsSample` (or `unlockHardwareDecoder`) starts VT.
    /// Waiting for a presented picture GOP-reset persisted LUT ~5 s later.
    private var hardwareDecoderUnlocked = false
    private var wantsFeedUpscale: Bool { feedUpscaler != .off }
    /// Fast/Quality enlarge a *baked* GPU frame (LUT / de-squeeze). They must
    /// not steal the HEVC layer for an identity view  -  that remake is what
    /// went black, and it also swallowed zebra / false colour into the same
    /// dead present.
    private var presentsOnMetal: Bool {
        prefersPixelBufferDisplay || (wantsFeedUpscale && effects.replacesIdentityFeed)
    }

    private var shouldStartVT: Bool {
        // AVC must keep the decoder that receives the first IDR. Switching from
        // compressed-layer decode to VT after enqueue loses its reference state.
        if liveCodec == .avc { return true }
        if prefersPixelBufferDisplay { return true }
        guard hardwareDecoderUnlocked else { return false }
        return needsDecodedSample || sessionOwnsVT
    }
    /// VT owns the picture so the hardware decoder is not shared with the display layer.
    private var usesPixelBufferDisplay: Bool { prefersPixelBufferDisplay || shouldStartVT }
    /// Test seam: the live VT session (if any) can decode samples stamped with
    /// the current format description. `adoptFormat` must keep this true.
    public var vtSessionAcceptsCurrentFormat: Bool { vt.sessionAcceptsCurrentFormat }

    /// Decode failed after the last presented picture  -  VT / layer is not
    /// producing frames right now. Fresh signal for `LinkDiagnoser`.
    public var isDecoderWedged: Bool {
        guard let error = lastDecodeErrorAt else { return false }
        if shouldStartVT, let lastDecodeErrorUptime = vt.lastDecodeErrorUptime {
            guard let outputAge = pipelineMetrics.outputAge else { return true }
            return ProcessInfo.processInfo.systemUptime - lastDecodeErrorUptime < outputAge
        }
        guard let presented = lastPresentedAt else { return true }
        return error > presented
    }

    /// Replacement Metal reports completion, not asynchronous bake admission.
    public var monitorPresentedAt: Date? {
        if effects.replacesIdentityFeed, let feed = ownedProcessedFeed, feed.hasPresentedFrame {
            return feed.lastPresentedAt
        }
        return lastPresentedAt
    }

    /// UDP may still be alive. This is a present hitch, not a recover enable.
    public var isPresentFrozen: Bool {
        let now = Date()
        return FeedPresentPolicy.isFrozen(
            secondsSinceLastPresent: monitorPresentedAt.map { now.timeIntervalSince($0) },
            secondsSinceLastDecodedFrame: lastSourceFrameAt.map { now.timeIntervalSince($0) })
    }

    /// Last HEVC picture is still on the layer; release it only when a VT frame is in hand.
    private var pendingLayerRelease = false
    /// LUT (or other GPU) just ended. Keep the last CI frame until the layer presents.
    private var layerHandoffPending = false
    private var lastNeedsSample = false
    private var lastNeedGPU = false
    private var lastOverlayFeed = false
    private var lastReplacesIdentity = false
    /// Last VT / assist source. LUT-off enqueues this on the layer so the canvas never goes black.
    private var lastDecodedBuffer: CVPixelBuffer?
    /// Passive chrome input. Never starts VT, requests an IDR, or changes the
    /// display owner; a compressed-layer-only session uses the public fallback.
    public var backdropSource: CVPixelBuffer? {
        displayedImageRemoved ? nil : lastDecodedBuffer
    }

    public var backdropPolicy: MonitorAssistPolicy {
        var result = effects
        result.image.clipByte = sampleSource?.exposureCeiling.clipByte(
            transfer: result.image.transfer) ?? result.image.clipByte
        // Until the current Metal product owns the picture, use identity.
        if result.needsGPUFeed, ownedProcessedFeed?.hasPresentedFrame != true {
            result.image.lutDimension = 0
            result.image.lutRGBA = Data()
            result.image.peaking = false
            result.image.zebra = false
            result.image.falseColor = false
            result.image.desqueezeFactor = 1
        }
        return result
    }
    private var lastDecodedTimeNs: Int64 = 0
    private var lastPresentHealthLogAt: Date?

    public init(configuration: MonitorVideoConfiguration = .init()) {
        self.configuration = configuration
        let source = MonitorVideoSourceLifetime()
        self.sourceLifetime = OSAllocatedUnfairLock(initialState: source)
        self.vt = VideoToolboxDecoder(stream: source.stream, hooks: .init(
            shouldRebuildSession: configuration.shouldRebuildSession,
            journal: configuration.assists.journal,
            logSubsystem: configuration.assists.logSubsystem))
        self.assistEngine = MonitorAssistEngine(configuration: configuration.assists)
        self.log = Logger(subsystem: configuration.assists.logSubsystem, category: "live-video")
        Task.detached(priority: .utility) { _ = MonitorImageCompositor.fusedPeakingAvailable }
    }

    /// Stable source identity, separate from VT rebuild generations. Capture before queuing input.
    nonisolated public var sourceToken: MonitorVideoSourceToken? {
        sourceLifetime.withLock { $0.token }
    }

    nonisolated private func accepts(_ token: MonitorVideoSourceToken?) -> Bool {
        let current = sourceLifetime.withLock { $0.token != nil && $0.token == token }
        let publication = samplePublication.withLock { $0 }
        return current && publication?.isActive != false
    }

    nonisolated private func accepts(
        _ source: MonitorVideoSourceToken?, generation: StreamGeneration
    ) -> Bool {
        accepts(source) && vt.fence.isCurrent(generation)
    }

    /// Applies a camera ISO report to this live source, even when playback owns the display.
    /// Capture the token before queuing a report. Retired reports and out-of-range ISOs preserve
    /// calibration. `nil` or a value of zero or less is an unreported ISO (Auto without its
    /// applied value): the source's profile decides (``ScopeClipProfile/unreportedISO``).
    @discardableResult public func updateSourceCalibration(
        iso: Int?, source: MonitorVideoSourceToken?
    ) -> Bool {
        guard accepts(source), let sampleSource, sampleBus?.isCurrent(sampleSource) == true
        else { return false }
        if let iso, iso > 0 {
            guard (50...102_400).contains(iso) else { return false }
            sampleSource.exposureCeiling.syncISO(iso)
        } else {
            guard sampleSource.exposureCeiling.unreportedISO != nil else { return false }
            sampleSource.exposureCeiling.syncISO(nil)
        }
        return true
    }

    /// Terminal retirement. Fences queued frames before releasing native and publication owners.
    open func close() {
        sourceLifetime.withLock { $0.close() }
        invalidateVT()
        finishDisplayWait(false)
        assistEngine.reset()
        sampleBus?.closeSource(sampleSource)
        sampleSource = nil
        lastDecodedBuffer = nil
        lastDecodedTimeNs = 0
        vt.dropFormat()
        ownedProcessedFeed?.invalidatePendingPresents()
        ownedProcessedFeed?.setOverlayChrome(false)
        ownedProcessedFeed?.isHidden = true
        processedFeed?.releaseOwnership(pictureOwnership)
        pictureOwnership = nil
        displayLayer.flushAndRemoveImage()
        displayedImageRemoved = true
    }

    /// A pixel-buffer source uses this same picture owner without constructing a second decoder.
    public func preparePixelBufferSource(transfer: MonitorTransfer) {
        guard sourceToken != nil else { return }
        prefersPixelBufferDisplay = true
        incomingTransfer = transfer
        assistEngine.updatePolicy(effects: effects, transfer: transfer)
    }

    public var health: MonitorVideoHealth {
        MonitorVideoHealth(
            source: sourceToken, pipelineGeneration: vt.fence.generation, codec: liveCodec,
            pictureSize: pictureSize.width > 1 && pictureSize.height > 1 ? pictureSize : nil,
            lastSourceFrameAt: lastSourceFrameAt, lastPresentedAt: lastPresentedAt,
            lastDisplayPresentedAt: monitorPresentedAt, lastRandomAccessAt: lastIrapAt, hasAcceptedRandomAccess: hasSubmittedRandomAccess,
            referenceRecoveryNeeded: referenceRecoveryNeeded, awaitingRandomAccess: awaitingIDR,
            nativeOutputExpected: nativeOutputExpected, outputAge: nativeOutputAge,
            displayReady: isDisplayReady, displayedImageRemoved: displayedImageRemoved,
            decoderFailed: isDecoderWedged, failure: lastDecodeErrorAt.map {
                MonitorVideoFailure(at: $0, status: lastDecodeStatus,
                    origin: lastDecodeOrigin, flags: lastDecodeFlags)
            }, pipeline: pipelineMetrics.snapshot)
    }

    public var pictureFlip: Bool { poseViewFlip != assistMirror }

    public func syncPictureFlip() {
        // Extra-mirror commits on the next present, not on the pose edge  -
        // flipping the last frame in place is the jarring swap.
    }

    /// New live host view  -  do not keep a presented flag from a torn-down layer.
    public func invalidatePictureFlipPresentation() {
        presentedPictureFlip = nil
        extraMirrorHold.reset()
    }

    /// Layer is in the view hierarchy with a real size  -  safe to enqueue the first IDR.
    public var isDisplayReady: Bool { vt.isDisplayReady }

    /// True while a VT session is allocated. LUT-off hands HEVC back to the display layer.
    public var videoToolboxActive: Bool { vt.session != nil }
    /// Successful `VTDecompressionSessionCreate` count. Repeated VPS/SPS/PPS must not bump this.
    public var vtRebuildCount: Int { vt.sessionCreateCount }

    /// Mid-session re-enable gate: display attached, and VT exists when this path needs it.
    public var isPresentationReady: Bool {
        guard sourceToken != nil, isDisplayReady else { return false }
        if shouldStartVT, vt.format != nil { return vt.session != nil }
        return true
    }

    nonisolated public static func shouldRebuildSession(status: OSStatus) -> Bool {
        status == kVTInvalidSessionErr
    }

    public func noteDisplayReady() {
        finishDisplayWait(isDisplayReady)
    }

    /// Wait until the picture host has laid out the layer. First connect used to enable
    /// before attach; those AUs were discarded and the GOP stayed black.
    @discardableResult
    public func waitUntilDisplayReady(timeout: Duration = .milliseconds(800)) async -> Bool {
        if isDisplayReady { return true }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            displayReadyCont = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self else { return }
                self.finishDisplayWait(self.isDisplayReady)
            }
        }
    }

    private func finishDisplayWait(_ ready: Bool) {
        guard let cont = displayReadyCont else { return }
        displayReadyCont = nil
        cont.resume(returning: ready)
    }

    public func attach(
        sampleBus: LiveFrameSampleBus,
        demand provider: @escaping () -> MonitorVideoDemand,
        transfer: @escaping () -> MonitorTransfer? = { nil }
    ) {
        self.sampleBus = sampleBus
        self.demandProvider = provider
        self.transferProvider = transfer
        let next = provider()
        if next != demand { demand = next }
        adoptIncomingTransfer(transfer())
        syncAssistPolicy()
    }

    /// One access unit in Annex-B form; the source adapter strips any wire marker.
    /// The source can carry HEVC or AVC. Returns true if a frame was enqueued for display.
    @discardableResult
    public func decode(accessUnit: [UInt8], source: MonitorVideoSourceToken?) -> Bool {
        guard accepts(source) else { return false }
        if let provided = demandProvider?(), provided != demand {
            demand = provided
        }
        adoptIncomingTransfer(transferProvider?())
        let receivedAt = ProcessInfo.processInfo.systemUptime
        recentInputUptimes.removeAll { receivedAt - $0 >= 1 }
        recentInputUptimes.append(receivedAt)
        var slices: [[UInt8]] = []
        var unitTypes: [Int] = []
        let nals = Hevc.nalUnits(accessUnit)
        if liveCodec == nil { liveCodec = LiveVideo.detect(nals: nals) }
        guard let liveCodec else { return false }
        let avc = liveCodec == .avc
        for nal in nals where !nal.isEmpty {
            if avc {
                let type = Avc.nalType(nal[0])
                nalTypesSeen.insert(type)
                unitTypes.append(type)
                if Avc.isKeyframeNal(type) {
                    sawKeyframe = true
                    lastKeyframeAt = Date()
                }
                switch type {
                case Avc.sps: sps = nal
                case Avc.pps:
                    pps = nal
                    buildFormatIfReady()
                case let t where Avc.isVCL(t): slices.append(nal)
                default: break
                }
            } else {
                let type = Hevc.nalType(nal[0])
                nalTypesSeen.insert(type)
                unitTypes.append(type)
                if Hevc.isKeyframeNal(type) {
                    sawKeyframe = true
                    lastKeyframeAt = Date()
                }
                switch type {
                case Hevc.vps: vps = nal
                case Hevc.sps: sps = nal
                case Hevc.pps:
                    pps = nal
                    buildFormatIfReady()
                case let t where Hevc.isVCL(t): slices.append(nal)
                default: break
                }
            }
        }
        let hasIDR =
            avc
            ? slices.contains { !$0.isEmpty && Avc.nalType($0[0]) == Avc.idr }
            : slices.contains { !$0.isEmpty && Hevc.isIRAP(Hevc.nalType($0[0])) }
        if pendingParameterChangeEnable {
            pendingParameterChangeEnable = false
            if !hasIDR
            {
                onParameterSetsChanged?()
            }
        }
        // A P-frame accepted by AVSampleBufferDisplayLayer is not a decoded
        // first picture. Without a random-access frame it can silently render
        // nothing, yet marking it presented would disable first-picture recovery.
        guard hasSubmittedRandomAccess || hasIDR else { return false }
        guard
            !slices.isEmpty && (!awaitingIDR || hasIDR)
        else { return false }
        guard let format = vt.format, let sample = vt.makeCompressedSample(slices, format: format),
            VideoToolboxDecoder.isPresentable(sample)
        else { return false }
        if hasIDR {
            if awaitingIDR {
                log.info("feed: IDR landed  -  release hold")
            }
            awaitingIDR = false
            // Session counts this hold as done on the next enable.
        }
        if shouldStartVT {
            // Keep the last HEVC picture on the layer. flushAndRemoveImage here
            // is the LUT-off / assist-toggle black canvas.
            if !vtOwnsHardwareDecode {
                pendingLayerRelease = lastPresentedAt != nil && !displayedImageRemoved
                vtOwnsHardwareDecode = true
            }
            if !effects.needsGPUFeed, !presentsOnMetal {
                displayLayer.isHidden = false
                ownedProcessedFeed?.isHidden = true
            }
            // Do not fall through to HEVC enqueue  -  that dual-decodes and can
            // fail the layer to black when presentProcessed misses one AU.
            submissionSequence &+= 1
            // Ages describe the moment before this unit, so an IRAP reports the previous one.
            let unit = FeedIncidentDecodeErrorContext(
                status: 0, nalTypes: unitTypes, accessUnitBytes: accessUnit.count,
                irapAge: lastIrapAt.map { Date().timeIntervalSince($0) },
                parameterSetChangeAge: lastParameterSetChangeUptime.map { receivedAt - $0 },
                inputHz: Double(recentInputUptimes.count))
            // kVTInvalidSessionErr fails the session for every later frame, and nothing else
            // rebuilds it while a media return owns repair. A random-access unit can start a
            // fresh session, so spend the rebuild here rather than reject the camera's answer.
            if hasIDR, vt.sessionFailed { rebuildVT(force: true) }
            let submitted = presentProcessed(sample, source: source, sequence: submissionSequence, unit: unit)
            if submitted && hasIDR {
                hasSubmittedRandomAccess = true
                referenceRecoveryNeeded = false
                lastIrapAt = Date()
                lastIrapSubmission = submissionSequence
            }
            return submitted
        } else {
            vtOwnsHardwareDecode = false
            displayLayer.isHidden = false
            ownedProcessedFeed?.isHidden = true
        }
        if displayLayer.requiresFlushToResumeDecoding { displayLayer.flush() }
        // Backpressure is not a failed layer. flush() here hitch-blacked a live GOP.
        guard displayLayer.isReadyForMoreMediaData else {
            // A dropped compressed frame is a missing reference, not backpressure only.
            if hasSubmittedRandomAccess { noteCompressedDiscontinuity() }
            return false
        }
        // A compressed frame skipped during the mirror hold left later P-frames
        // without their reference. Decode it, just do not show it.
        let generation = vt.fence.generation
        let mirrorHold = !commitPictureFlipIfNeeded(source: source, generation: generation)
        guard accepts(source, generation: generation) else { return false }
        if mirrorHold { VideoToolboxDecoder.markDoNotDisplay(sample) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.enqueue(sample)
        CATransaction.commit()
        if displayLayer.status == .failed {
            displayLayer.flush()
            if displayLayer.status == .failed {
                displayedImageRemoved = true
                flushForRecovery()
                noteDecodeError()
                return false
            }
        }
        if hasIDR {
            hasSubmittedRandomAccess = true
            referenceRecoveryNeeded = false
            lastIrapAt = Date()
        }
        if mirrorHold { return true }
        finishLayerHandoffIfNeeded()
        lastSourceFrameAt = Date()
        notePresentedFrame(sampleRate: true)
        return true
    }

    /// Single entry for live VT, the simulator clip, and tests. A decoded `CVPixelBuffer` is enough.
    /// Assist work is off-main; this method does not hop to MainActor before enqueueing.
    nonisolated public func submitDecodedFrame(
        _ imageBuffer: CVPixelBuffer,
        policy: MonitorAssistPolicy? = nil,
        transfer: MonitorTransfer? = nil,
        isNewSourceFrame: Bool = true,
        generation: Int? = nil,
        timeNs: Int64 = 0,
        source: MonitorVideoSourceToken? = nil
    ) {
        let source = source ?? sourceToken
        guard accepts(source) else { return }
        let lease = vt.fence.lease(
            imageBuffer,
            generation: generation.map { StreamGeneration(UInt64(truncatingIfNeeded: $0)) },
            timeNs: timeNs)
        submitDecodedFrame(
            lease, policy: policy, transfer: transfer, isNewSourceFrame: isNewSourceFrame,
            source: source)
    }

    /// Lease form of the entry above. A lease from an older generation is released unused.
    nonisolated public func submitDecodedFrame(
        _ lease: DecodedFrameLease,
        policy: MonitorAssistPolicy? = nil,
        transfer: MonitorTransfer? = nil,
        isNewSourceFrame: Bool = true,
        source: MonitorVideoSourceToken? = nil
    ) {
        let source = source ?? sourceToken
        let generation = lease.generation
        guard accepts(source), lease.stream == vt.fence.stream,
            vt.fence.isCurrent(generation), let imageBuffer = lease.pixelBuffer else {
            lease.release()
            return
        }
        let sourceTime = Date()
        let sourceTimeNs =
            lease.timeNs != 0
            ? lease.timeNs
            : (isNewSourceFrame ? Int64(clamping: DispatchTime.now().uptimeNanoseconds) : 0)
        let publicationSource = samplePublication.withLock { $0 }
        guard publicationSource?.isActive != false else { lease.release(); return }
        if isNewSourceFrame { onIdentityFrame?(imageBuffer) }
        guard accepts(source, generation: generation), publicationSource?.isActive != false else {
            lease.release()
            return
        }
        let assistSubmittedAt = ProcessInfo.processInfo.systemUptime
        if isNewSourceFrame { pipelineMetrics.assistInput() }
        // One MainActor hop per engine callback  -  a second per-frame Task for the frame
        // counters doubled main-queue pressure at 25 fps for two one-line writes.
        assistEngine.submit(imageBuffer, effects: policy, transfer: transfer, timeNs: sourceTimeNs == 0 ? nil : sourceTimeNs)
        {
            [weak self] result in
            let completedAt = ProcessInfo.processInfo.systemUptime
            if isNewSourceFrame, result.shouldPresent,
                self?.vt.fence.isCurrent(generation) == true, self?.accepts(source) == true
            {
                self?.pipelineMetrics.assistOutput(
                    at: completedAt, submittedAt: assistSubmittedAt)
            }
            Task { @MainActor [weak self] in
                // The source lease ends here: published, or refused as stale.
                defer { lease.release() }
                guard let self, self.accepts(source), self.vt.fence.isCurrent(generation),
                    publicationSource?.isActive != false else { return }
                if isNewSourceFrame, result.shouldPresent {
                    self.pipelineMetrics.adopted(
                        at: ProcessInfo.processInfo.systemUptime, completedAt: completedAt)
                }
                let presented = self.applyAssistResult(
                    result, source: source, generation: generation,
                    publicationSource: publicationSource, isNewSourceFrame: isNewSourceFrame)
                guard self.accepts(source, generation: generation),
                    publicationSource?.isActive != false else { return }
                // Cached repaints cannot refresh source liveness.
                if result.shouldPresent && isNewSourceFrame {
                    self.lastSourceFrameAt = sourceTime
                    self.sampleBus?.noteDecodedFrame(publicationSource)
                }
                if presented && isNewSourceFrame {
                    self.publishPreview(result)
                    guard self.accepts(source, generation: generation),
                        publicationSource?.isActive != false else { return }
                    self.notePresentedFrame(sampleRate: true)
                }
            }
        }
    }

    open func reset() {
        guard sourceToken != nil else { return }
        sourceLifetime.withLock { $0.advance() }
        invalidateVT()
        hasSubmittedRandomAccess = false
        referenceRecoveryNeeded = false
        finishDisplayWait(false)
        vt.dropFormat()
        liveCodec = nil
        vps = nil
        sps = nil
        pps = nil
        nalTypesSeen.removeAll()
        pictureSize = .zero
        isVerticalPicture = false
        onPictureSizeChanged?()
        vt.clearErrors()
        firstDecodeError = nil
        outputsAtLastError = nil
        recentInputUptimes.removeAll()
        lastParameterSetChangeUptime = nil
        lastKeyframeAt = nil
        lastPresentedAt = nil
        lastSourceFrameAt = nil
        sawKeyframe = false
        displayedImageRemoved = false
        awaitingIDR = false
        pendingParameterChangeEnable = false
        pendingLayerRelease = false
        layerHandoffPending = false
        lastNeedsSample = false
        lastNeedGPU = false
        lastOverlayFeed = false
        lastReplacesIdentity = false
        sessionOwnsVT = false
        hardwareDecoderUnlocked = false
        lastDecodedBuffer = nil
        lastDecodedTimeNs = 0
        lastPresentHealthLogAt = nil
        presentedPictureFlip = nil
        extraMirrorHold.reset()
        vt.resetCounters()
        assistEngine.reset()
        pipelineMetrics.reset()
        if let sampleBus, sampleBus.isCurrent(sampleSource) {
            sampleBus.closeSource(sampleSource)
            sampleSource = sampleBus.openSource(.live)
            if let sampleSource { assistEngine.adopt(exposureCeiling: sampleSource.exposureCeiling) }
        }
        // VT was invalidated before clearing state. Release its old layer image
        // too: an in-app disconnect must not leave a picture from the prior GOP.
        vtOwnsHardwareDecode = false
        displayLayer.isHidden = false
        ownedProcessedFeed?.invalidatePendingPresents()
        ownedProcessedFeed?.setOverlayChrome(false)
        ownedProcessedFeed?.isHidden = true
        displayLayer.flushAndRemoveImage()
        displayedImageRemoved = true
    }

    /// Drop format so the next IDR rebuilds it. Keeps the last displayed picture.
    /// The session may send a one-shot random-access request after this  -  never a 1 Hz re-enable loop.
    public func flushForRecovery() {
        ownedProcessedFeed?.invalidatePendingPresents()
        if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
            displayLayer.flush()
        }
        if displayLayer.status == .failed { displayedImageRemoved = true }
        dropFormatForRecovery()
        pendingParameterChangeEnable = false
        beginIDRHold()
    }

    /// Source recovery stage 2: rebuild a wedged VT session. Keeps the last frame.
    /// Does not send enable  -  caller must wait for `isPresentationReady`.
    @discardableResult
    public func rebuildPresentation() -> Bool {
        if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
            displayLayer.flush()
        }
        if displayLayer.status == .failed { displayedImageRemoved = true }
        if vt.format != nil {
            rebuildVT(force: true)
            if shouldStartVT, vt.session == nil { dropFormatForRecovery() }
        } else {
            dropFormatForRecovery()
        }
        beginIDRHold()
        return isPresentationReady
    }

    /// A current IRAP can restore references between the source recovery policy snapshot
    /// and its scheduled owner. MainActor makes this check and mutation atomic.
    /// Returns whether a rebuild was spent, independently of display readiness.
    public func rebuildPresentationIfNeeded(referenceLossOnly: Bool) -> Bool {
        if referenceLossOnly, !referenceRecoveryNeeded { return false }
        _ = rebuildPresentation()
        return true
    }

    /// Missing compressed references cannot be repaired by dropping another
    /// arbitrary frame. Retain the image and let the source recovery policy request an IRAP.
    public func noteCompressedDiscontinuity() {
        referenceRecoveryNeeded = referenceRecoveryNeeded || hasSubmittedRandomAccess
        hasSubmittedRandomAccess = false
        beginIDRHold()
        configuration.assists.journal("decoder: compressedDiscontinuity awaitingRandomAccess=1")
    }

    /// After a GOP-reset enable, ignore P-frames until the IDR AU.
    public func beginIDRHold() {
        awaitingIDR = true
    }

    /// UDP is alive and the last picture is still on the layer  -  do not wait
    /// forever for an IRAP that a PLI did not cut.
    public func endIDRHold() {
        guard canReleaseIDRHold else { return }
        awaitingIDR = false
    }

    private func dropFormatForRecovery() {
        vt.dropFormat()
        liveCodec = nil
        vps = nil
        sps = nil
        pps = nil
        pictureSize = .zero
        invalidateVT()
        vtOwnsHardwareDecode = false
    }

    private func removeDisplayedImage() {
        guard
            FeedPresentPolicy.shouldFlushDisplayedImage(
                disconnecting: false,
                layerFailed: displayLayer.status == .failed,
                nextFrameReady: lastDecodedBuffer != nil)
        else { return }
        displayLayer.flushAndRemoveImage()
        displayedImageRemoved = true
        log.info("feed: black removed displayed image")
    }

    private func notePresentedFrame(sampleRate: Bool = false) {
        sourcePresentations += 1
        lastPresentedAt = Date()
        displayedImageRemoved = false
        if sampleRate { onPresentedFrame?() }
    }

    /// After the first GOP is rolling. Calling this on the first present
    /// sent a second `random-access request`, held P-frames, and froze the canvas on LINK.
    public func unlockHardwareDecoder() {
        guard !hardwareDecoderUnlocked else { return }
        hardwareDecoderUnlocked = true
        applyEffectsChange()
    }

    /// The source and decoder may pause in the background. Keep the
    /// last picture. Do **not** begin an IDR hold here  -  that dropped every
    /// P-frame after Control Center when random-access request was then skipped.
    public func prepareAfterForeground() {
        if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
            displayLayer.flush()
        }
        if displayLayer.status == .failed { displayedImageRemoved = true }
        // Preserve the native reference chain on app return. The source recovery policy owns
        // an evidenced decoder rebuild and its one random-access request.
    }

    private func releaseLayerDecoderIfNeeded() {
        // Do not flushAndRemoveImage  -  the layer keeps the last picture so LUT-off
        // and false stalls never paint black.
        pendingLayerRelease = false
    }

    private func applyEffectsChange() {
        guard sourceToken != nil else { return }
        configuration.policyChanged(effects.replacesIdentityFeed)
        // Parameter sets + assist: start VT now. Gating on lastPresentedAt
        // delayed persisted LUT until the 5 s unlock, then sent random-access request.
        if hasFormat, needsDecodedSample || hdrDisplayEnabled {
            hardwareDecoderUnlocked = true
        }
        if needsDecodedSample || hdrDisplayEnabled { sessionOwnsVT = true }
        ownedProcessedFeed?.resetPresentDedup()
        let needVT = shouldStartVT
        let needGPU = effects.needsGPUFeed || presentsOnMetal
        let overlay = effects.needsOverlayFeed && !presentsOnMetal
        let replace = effects.replacesIdentityFeed
        // LUT 50/50 is a compositor flag on an already-replacing cube. Do not
        // rebuild VT, hold IDR, or flip layer ownership  -  that was the
        // Reconnecting / force-quit (#218).
        let pathUnchanged =
            needVT == lastNeedsSample && needGPU == lastNeedGPU && overlay == lastOverlayFeed
            && replace == lastReplacesIdentity
        // Identity (!needGPU) must still restore the HEVC layer even when the
        // flags look unchanged  -  tests and LUT-off cover Metal that was left
        // visible. Skip only while we stay on an already-running GPU path
        // (LUT 50/50 is a compositor flag, not a layer/VT tear).
        if pathUnchanged, needGPU, !(needVT && vt.session == nil && vt.format != nil) {
            syncAssistPolicy()
            return
        }
        // A fresh VT session cannot decode mid-GOP P-frames. Once VT owns the
        // session, assist off is a present-path change  -  keep decoding.
        let vtStarting = needVT && !lastNeedsSample
        let releasingAssist = !needsDecodedSample && lastNeedsSample && sessionOwnsVT
        if needVT {
            if vt.session == nil, vt.format != nil { rebuildVT() }
            vtOwnsHardwareDecode = vt.session != nil
        }
        if !needGPU {
            // Opaque MonitorPictureHost covers Rec.709 / HLG even when the layer has a picture.
            ownedProcessedFeed?.invalidatePendingPresents()
            layerHandoffPending = false
            if !vtStarting { awaitingIDR = false }
            displayLayer.isHidden = false
            ownedProcessedFeed?.setOverlayChrome(false)
            ownedProcessedFeed?.isHidden = true
            if let buffer = lastDecodedBuffer, isDisplayReady {
                _ = enqueueDecodedFrame(
                    buffer, recoverOnFailure: false, isNewSourceFrame: false)
            }
        } else if overlay {
            // Zebra / peaking / false colour ride on top of the identity layer.
            displayLayer.isHidden = false
        }
        lastNeedsSample = needVT
        lastNeedGPU = needGPU
        lastOverlayFeed = overlay
        lastReplacesIdentity = replace
        syncAssistPolicy()
        if vtStarting {
            // Empty VT cannot join mid-GOP. Hold even if the session skips a
            // second random-access request because the live-start enable is still in flight.
            beginIDRHold()
        }
        if vtStarting && hasFormat && lastPresentedAt != nil {
            log.info("feed: start VT for assist  -  one random-access request")
            configuration.assists.journal("feed: start VT for assist  -  one random-access request")
            onHandoffNeedsIDR?()
        } else if releasingAssist {
            log.info("feed: assist off  -  keep VT, no random-access request")
            configuration.assists.journal("feed: assist off  -  keep VT, no random-access request")
        }
    }

    private func finishLayerHandoffIfNeeded() {
        guard layerHandoffPending else { return }
        layerHandoffPending = false
        displayLayer.isHidden = false
        if effects.needsOverlayFeed, !presentsOnMetal,
            ownedProcessedFeed?.hasPresentedFrame == true
        {
            ownedProcessedFeed?.isHidden = false
        } else if !effects.needsOverlayFeed {
            ownedProcessedFeed?.setOverlayChrome(false)
            ownedProcessedFeed?.isHidden = true
        }
    }

    private func syncAssistPolicy() {
        let fx = demandProvider?().assists ?? effects
        let transfer = transferProvider?() ?? incomingTransfer ?? .rec709
        assistEngine.updatePolicy(effects: fx, transfer: transfer)
    }

    /// Replacing Metal owns the picture only after a drawable lands.
    /// Until then the compressed / VT layer stays the identity.
    private func adoptReplacingMetalFeed(_ feed: MonitorPictureHost) {
        guard
            FeedPresentPolicy.replaceOwnsPicture(
                hasPresentedFrame: feed.hasPresentedFrame,
                lastPresentWasOverlay: feed.lastPresentWasOverlay)
        else { return }
        feed.isHidden = false
        displayLayer.isHidden = true
        releaseLayerDecoderIfNeeded()
    }

    private func adoptPresentedFeed() {
        guard let feed = ownedProcessedFeed else { return }
        if !effects.needsGPUFeed {
            if hdrDisplayEnabled, feed.hasPresentedFrame {
                adoptReplacingMetalFeed(feed)
                return
            }
            feed.setOverlayChrome(false)
            feed.isHidden = true
            displayLayer.isHidden = false
            return
        }
        if effects.needsOverlayFeed {
            if feed.hasPresentedFrame { feed.isHidden = false }
            displayLayer.isHidden = false
            return
        }
        if effects.replacesIdentityFeed {
            adoptReplacingMetalFeed(feed)
        }
        maybeLogPresentHealth()
    }

    private func maybeLogPresentHealth() {
        guard effects.needsGPUFeed else { return }
        let now = Date()
        if let last = lastPresentHealthLogAt, now.timeIntervalSince(last) < 2 { return }
        lastPresentHealthLogAt = now
        let frozen = isPresentFrozen ? 1 : 0
        let line = ownedProcessedFeed?.debugLine ?? "feed present none frozen=\(frozen)"
        configuration.assists.journal(line)
        if isPresentFrozen {
            log.info(
                "feed: freeze lastFrame=\(self.lastPresentedAt.map { now.timeIntervalSince($0) } ?? -1, format: .fixed(precision: 1), privacy: .public)s (keep picture)"
            )
        }
    }

    private func publishPreview(_ result: MonitorAssistEngine.Result) {
        // No external preview: skip the per-frame CIImage. Wrapping the VT buffer here
        // crashed in CVImageBufferCreateColorSpaceFromAttachments on the Simulator.
        guard demand.externalPreview, onPreviewFrame != nil else { return }
        let cubeOwnsPicture =
            result.needsGPU && effects.replacesIdentityFeed && !result.overlayOnly
        let preview: CIImage
        if cubeOwnsPicture {
            preview = result.output
        } else if !result.identity.extent.isEmpty {
            preview = result.identity
        } else {
            preview = CIImage(cvPixelBuffer: result.source)
        }
        // Identity JPEGs encode the VT buffer. A cube product has no matching
        // buffer  -  passing source there would drop the grade.
        onPreviewFrame?(
            preview, cubeOwnsPicture ? nil : result.source,
            cubeOwnsPicture && result.unmanagedBake)
    }

    private func applyAssistResult(
        _ result: MonitorAssistEngine.Result, source: MonitorVideoSourceToken?,
        generation: StreamGeneration,
        publicationSource: LiveFrameSampleBus.Source?,
        isNewSourceFrame: Bool = true
    ) -> Bool {
        func isCurrent() -> Bool {
            accepts(source, generation: generation) && publicationSource?.isActive != false
        }
        guard isCurrent() else { return false }
        // The inspector borrows raw main-feed pixels even when no scope is
        // enabled. Retaining the buffer performs no copy or scope calculation;
        // only an actual scope bundle advances the bus's observable generation.
        if let sampleBus {
            guard sampleBus.publish(publicationSource,
            source: result.source,
            transfer: result.transfer,
            reportedTransfer: result.transfer,
            bundle: result.bundle) else { return false }
        }
        guard isCurrent() else { return false }
        if result.shouldPresent {
            lastDecodedBuffer = result.source
            lastDecodedTimeNs = result.timeNs ?? 0
            if let onSourceFrame {
                let lease = vt.fence.lease(
                    result.source, generation: generation, timeNs: result.timeNs ?? 0)
                vt.fence.publish(lease, to: onSourceFrame)
                lease.release()
            }
            guard isCurrent() else { return false }
            onSourceAdvanced?()
            guard isCurrent() else { return false }
        }
        if !result.shouldPresent { return false }
        var presentedIdentity = false

        let replaceIdentity = effects.replacesIdentityFeed
        let metalOwnsPicture =
            replaceIdentity
            && FeedPresentPolicy.replaceOwnsPicture(
                hasPresentedFrame: ownedProcessedFeed?.hasPresentedFrame ?? false,
                lastPresentWasOverlay: ownedProcessedFeed?.lastPresentWasOverlay ?? false)

        // Identity picture: same VT buffer source-pixel consumers already see. Never skip this
        // for a Metal remake  -  NSNull / 10-bit layer enqueue is how the well
        // went black while tracking still worked.
        if usesPixelBufferDisplay, !metalOwnsPicture {
            displayLayer.isHidden = false
            presentedIdentity = enqueueDecodedFrame(
                result.source, recoverOnFailure: false, isNewSourceFrame: isNewSourceFrame,
                source: source, generation: generation)
        } else if !replaceIdentity {
            displayLayer.isHidden = false
        }
        guard isCurrent() else { return false }

        if !result.needsGPU || !effects.needsGPUFeed {
            if hdrDisplayEnabled, let feed = ownedProcessedFeed {
                let identity = CIImage(cvPixelBuffer: result.source)
                if feed.display(identity, unmanaged: false, overlay: false, timeNs: result.timeNs) {
                    adoptReplacingMetalFeed(feed)
                    return true
                }
            }
            if !metalOwnsPicture {
                ownedProcessedFeed?.setOverlayChrome(false)
                ownedProcessedFeed?.isHidden = true
            }
            return presentedIdentity
        }
        guard let feed = ownedProcessedFeed else { return presentedIdentity }
        if metalOwnsPicture, !commitPictureFlipIfNeeded(source: source, generation: generation) {
            return presentedIdentity
        }

        if result.overlayOnly, !replaceIdentity, !prefersPixelBufferDisplay {
            // Transparent stripes on top of the layer. Do not unhide here  -
            // an unpresented CAMetalLayer is an opaque black plate.
            let painted = feed.display(
                result.output, unmanaged: true, overlay: true, timeNs: result.timeNs)
            if !painted {
                feed.setOverlayChrome(false)
                feed.isHidden = true
            }
            return presentedIdentity
        }

        if prefersPixelBufferDisplay, result.overlayOnly {
            let picture = MonitorImageCompositor.place(result.output, over: result.identity)
            if feed.display(picture, unmanaged: false, overlay: false, timeNs: result.timeNs)
                || feed.display(result.identity, unmanaged: false, timeNs: result.timeNs)
            {
                adoptReplacingMetalFeed(feed)
                return true
            }
            return presentedIdentity
        }

        if replaceIdentity {
            if feed.display(
                result.output, unmanaged: result.unmanagedBake, timeNs: result.timeNs)
                || feed.display(result.identity, unmanaged: false, timeNs: result.timeNs)
            {
                adoptReplacingMetalFeed(feed)
                return true
            }
        }
        return presentedIdentity
    }

    private func buildFormatIfReady() {
        if liveCodec == .avc {
            buildAvcFormatIfReady()
            return
        }
        guard let vps, let sps, let pps else { return }
        if vt.format != nil, vps == vt.builtVPS, sps == vt.builtSPS, pps == vt.builtPPS {
            if shouldStartVT, vt.session == nil { rebuildVT() }
            return
        }
        let changing = EncoderPresentPath.parameterSetsChanged(
            hadFormat: vt.format != nil,
            previousVPS: vt.builtVPS, previousSPS: vt.builtSPS, previousPPS: vt.builtPPS,
            nextVPS: vps, nextSPS: sps, nextPPS: pps)
        if let fmt = VideoToolboxDecoder.makeHEVCFormat(vps: vps, sps: sps, pps: pps) {
            adoptFormat(fmt, vps: vps, sps: sps, pps: pps, changing: changing)
        }
    }

    private func buildAvcFormatIfReady() {
        guard let sps, let pps else { return }
        if vt.format != nil, sps == vt.builtSPS, pps == vt.builtPPS {
            if shouldStartVT, vt.session == nil { rebuildVT() }
            return
        }
        let changing = EncoderPresentPath.parameterSetsChanged(
            hadFormat: vt.format != nil,
            previousVPS: nil, previousSPS: vt.builtSPS, previousPPS: vt.builtPPS,
            nextVPS: nil, nextSPS: sps, nextPPS: pps)
        if let fmt = VideoToolboxDecoder.makeAVCFormat(sps: sps, pps: pps) {
            adoptFormat(fmt, vps: nil, sps: sps, pps: pps, changing: changing)
        }
    }

    private func adoptFormat(
        _ fmt: CMFormatDescription, vps: [UInt8]?, sps: [UInt8], pps: [UInt8], changing: Bool
    ) {
        vt.adoptFormat(fmt, vps: vps, sps: sps, pps: pps)
        if changing { lastParameterSetChangeUptime = ProcessInfo.processInfo.systemUptime }
        let previousSize = pictureSize
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        let next = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        if next.width > 1, next.height > 1 {
            pictureSize = next
            isVerticalPicture = FeedRaster.isVertical(
                width: Int(next.width), height: Int(next.height))
            if next != previousSize {
                // Raster changes are rare (format / screen flip); the size decides layout.
                configuration.assists.journal(
                    "decoder: picture \(Int(next.width))x\(Int(next.height)) vertical=\(isVerticalPicture ? 1 : 0)"
                )
                onPictureSizeChanged?()
            }
        }
        let sizeChanged =
            previousSize.width > 1 && previousSize.height > 1 && previousSize != next
        // Same-raster VPS/SPS (zoom / FORMAT / color) must not tear or IDR-hold.
        // That hold + skipped random-access request (UDP alive) is a black well with live HUD.
        if changing,
            EncoderPresentPath.shouldRebuildDecoderAfterParameterChange(
                pictureSizeChanged: sizeChanged, accessUnitHasIDR: false)
        {
            handleEncoderFormatChange()
        }
        // Same raster, new sets: VT decides. Keeping a session that refuses the
        // new SPS fails every frame with no log  -  frozen well, live HUD.
        if vt.session != nil,
            EncoderPresentPath.shouldRebuildDecoderForRejectedFormat(
                parameterSetsChanged: changing,
                sessionAcceptsFormat: vt.sessionAccepts(fmt))
        {
            log.info("feed: VT refused new parameter sets  -  rebuild VT, keep picture")
            configuration.assists.journal("feed: VT refused new parameter sets  -  rebuild VT, keep picture")
            rebuildVT(force: true)
        }
        // Persisted LUT/scopes: start VT on this parameter-set AU. `onHandoffNeedsIDR`
        // still requires a picture, so the first GOP is not cut.
        if needsDecodedSample {
            hardwareDecoderUnlocked = true
        }
        if shouldStartVT {
            rebuildVT(force: changing && sizeChanged)
            lastNeedsSample = true
        }
    }

    /// Screen flip / vertical mode restarts the camera encoder. The old VT
    /// session and sample-buffer layer format cannot decode the new GOP.
    /// Same-raster SPS (zoom) must not call this  -  IDR-hold without enable
    /// blacks the well while control observations stay live.
    private func handleEncoderFormatChange() {
        log.info(
            "feed: encoder parameter sets changed \(Int(self.pictureSize.width))x\(Int(self.pictureSize.height))"
        )
        if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
            displayLayer.flush()
        }
        invalidateVT()
        if EncoderPresentPath.shouldBeginIDRHoldAfterParameterChange(
            pictureSizeChanged: true, accessUnitHasIDR: false)
        {
            beginIDRHold()
        }
        pendingParameterChangeEnable = true
    }

    private func invalidateVT() {
        // The runtime fences successful callbacks before teardown can deliver its final output.
        vt.invalidateSession()
        hasSubmittedRandomAccess = false
    }

    private func rebuildVT(force: Bool = false) {
        guard shouldStartVT, vt.needsSession(force: force) else { return }
        invalidateVT()
        if vt.openSession() {
            sessionOwnsVT = true
            vtOwnsHardwareDecode = true
        }
    }

    /// Extra-mirror the host view with the next present. `false` keeps the last picture.
    @discardableResult
    private func commitPictureFlipIfNeeded(
        source: MonitorVideoSourceToken?, generation: StreamGeneration
    ) -> Bool {
        guard accepts(source, generation: generation) else { return false }
        switch extraMirrorHold.step(want: pictureFlip, now: CFAbsoluteTimeGetCurrent()) {
        case .unchanged:
            if presentedPictureFlip != pictureFlip, let apply = applyPictureMirror {
                let mirrored = pictureFlip
                apply(mirrored)
                guard accepts(source, generation: generation) else { return false }
                presentedPictureFlip = mirrored
            }
            return accepts(source, generation: generation)
        case .hold:
            return false
        case .commit(let mirrored):
            applyPictureMirror?(mirrored)
            guard accepts(source, generation: generation) else { return false }
            presentedPictureFlip = mirrored
            return accepts(source, generation: generation)
        }
    }

    /// Zero-copy present of a VT frame. Uncompressed  -  the layer must not start a second HEVC decoder.
    @discardableResult
    public func enqueueDecodedFrame(
        _ imageBuffer: CVPixelBuffer, recoverOnFailure: Bool = true, isNewSourceFrame: Bool = true
    ) -> Bool {
        enqueueDecodedFrame(
            imageBuffer, recoverOnFailure: recoverOnFailure, isNewSourceFrame: isNewSourceFrame,
            source: sourceToken, generation: vt.fence.generation)
    }

    private func enqueueDecodedFrame(
        _ imageBuffer: CVPixelBuffer, recoverOnFailure: Bool, isNewSourceFrame: Bool,
        source: MonitorVideoSourceToken?, generation: StreamGeneration
    ) -> Bool {
        guard accepts(source, generation: generation),
            commitPictureFlipIfNeeded(source: source, generation: generation) else { return false }
        guard VideoToolboxDecoder.isPresentable(imageBuffer) else { return false }
        // VT output keeps one size and color tagging per session; the runtime reuses its description.
        guard let sample = vt.makeDecodedSample(imageBuffer) else { return false }
        if displayLayer.requiresFlushToResumeDecoding { displayLayer.flush() }
        guard displayLayer.isReadyForMoreMediaData else { return false }
        releaseLayerDecoderIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.enqueue(sample)
        CATransaction.commit()
        if displayLayer.status == .failed {
            if recoverOnFailure {
                displayedImageRemoved = true
                flushForRecovery()
                noteDecodeError()
            }
            return false
        }
        finishLayerHandoffIfNeeded()
        if isNewSourceFrame {
            configuration.decodeEvent(.presented)
            guard accepts(source, generation: generation) else { return false }
            notePresentedFrame()
        } else {
            displayedImageRemoved = false
        }
        return true
    }

    /// Decode to a pixel buffer. GPU fx and scopes run on `MonitorAssistEngine` (off-main).
    @discardableResult
    private func presentProcessed(
        _ sample: CMSampleBuffer, source: MonitorVideoSourceToken?, sequence: UInt64,
        unit: FeedIncidentDecodeErrorContext
    ) -> Bool {
        guard accepts(source) else { return false }
        if vt.session == nil, vt.format != nil { rebuildVT() }
        guard accepts(source), vt.session != nil, !vt.sessionFailed else { return false }
        let fx = effects
        let transfer = transferProvider?() ?? incomingTransfer ?? .rec709
        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression]
        let gen = vt.fence.generation
        let err = decodeFrame(
            sample, flags: flags, generation: gen, policy: fx, transfer: transfer,
            source: source, sequence: sequence, unit: unit)
        return err == noErr && accepts(source, generation: gen)
    }

    public func noteDecodeError(
        status: OSStatus = 0, origin: String = "display", flags: UInt32 = 0
    ) {
        // A newly failed session rejects every later frame until a rebuild. Report it as
        // known reference loss so the source recovery policy repairs on its next tick, not after two
        // seconds of inferred output silence.
        if vt.noteError(status: status, origin: origin, flags: flags), origin != "create",
            lastPresentedAt != nil
        {
            referenceRecoveryNeeded = true
        }
    }

    /// A new episode starts at the first error after native output (or the first ever).
    private func noteFirstDecodeError(_ unit: FeedIncidentDecodeErrorContext, status: OSStatus) {
        let outputs = pipelineMetrics.totals.output
        defer { outputsAtLastError = outputs }
        guard outputsAtLastError != outputs else { return }
        var first = unit
        first.status = status
        firstDecodeError = first
    }

    /// F08 native evidence (macOS 26.5 and 27 VideoToolbox; field build 192 matches): once a
    /// picture is rejected with BadData, every later dependent picture fails too and no output
    /// returns until an IRAP, on the same session or a rebuilt one. The iOS 26.2 simulator
    /// decoder conceals instead: one BadData at most, then pictures predicted from the loss.
    /// Either way only an IRAP repairs the picture, so this is known reference loss now, the
    /// same as a dropped compressed reference, instead of two seconds of output silence later.
    /// ponytail: every BadData counts, without NAL reference classification. A stream with
    /// non-reference pictures would hold until its next IRAP after one of those failed;
    /// classify by NAL type if such a stream appears.
    private func noteNativeBadData(sequence: UInt64) {
        guard sequence > lastIrapSubmission else { return }
        noteCompressedDiscontinuity()
    }

    /// Both native failure paths retain the submitted source, decoder and reference sequence.
    private func noteNativeFailure(
        status: OSStatus, origin: String, flags: UInt32 = 0,
        source: MonitorVideoSourceToken?, generation: StreamGeneration,
        sequence: UInt64, unit: FeedIncidentDecodeErrorContext
    ) {
        guard accepts(source, generation: generation) else { return }
        noteDecodeError(status: status, origin: origin, flags: flags)
        // Diagnostics may synchronously retire the source or rebuild its decoder.
        guard accepts(source, generation: generation) else { return }
        noteFirstDecodeError(unit, status: status)
        if status == kVTVideoDecoderBadDataErr { noteNativeBadData(sequence: sequence) }
    }

    /// Called by the existing 1 Hz session publisher, including during silence.
    public func takePipelineTimingLine() -> String {
        pipelineMetrics.takeLine(vtActive: vt.session != nil)
    }

    private func decodeFrame(
        _ sample: CMSampleBuffer,
        flags: VTDecodeFrameFlags,
        generation: StreamGeneration,
        policy: MonitorAssistPolicy,
        transfer: MonitorTransfer,
        source: MonitorVideoSourceToken?,
        sequence: UInt64,
        unit: FeedIncidentDecodeErrorContext
    ) -> OSStatus {
        let submittedAt = ProcessInfo.processInfo.systemUptime
        pipelineMetrics.submitted()
        configuration.decodeEvent(.submitted)
        guard accepts(source, generation: generation) else { return kVTInvalidSessionErr }
        let output: @Sendable (VideoToolboxDecoder.Output) -> Void = { [weak self] output in
            guard let self else { return }
            switch output {
            case .failed(let status, let infoFlags):
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.noteNativeFailure(
                        status: status, origin: "callback", flags: infoFlags.rawValue,
                        source: source, generation: generation, sequence: sequence, unit: unit)
                }
            case .frame(let lease):
                guard self.accepts(source), self.vt.fence.isCurrent(generation),
                    !self.configuration.discardOutput() else {
                    lease.release()
                    return
                }
                self.configuration.decodeEvent(.decoded)
                self.pipelineMetrics.decoded(
                    at: ProcessInfo.processInfo.systemUptime, submittedAt: submittedAt)
                if let buffer = lease.pixelBuffer { self.vt.logFirstOutput(buffer) }
                self.submitDecodedFrame(lease, policy: policy, transfer: transfer, source: source)
            }
        }
        let result = nativeSubmission?(vt, sample, flags, generation, output)
            ?? vt.decode(sample, flags: flags, generation: generation, output: output)
        if result == noErr {
            if accepts(source, generation: generation) { pipelineMetrics.accepted() }
        } else {
            noteNativeFailure(status: result, origin: "submit", source: source,
                generation: generation, sequence: sequence, unit: unit)
        }
        return result
    }
}

#endif
