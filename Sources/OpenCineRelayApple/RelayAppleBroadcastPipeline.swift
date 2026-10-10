#if canImport(VideoToolbox) && canImport(CoreGraphics)
    import CoreGraphics
    import Foundation
    import OpenCineRelay

    /// Cadence/adaptation and independent HEVC/JPEG stages for an already-owned picture. Typed
    /// metadata and JPEG SDK conversion are bounded adapters, never scheduling/host policy.
    @MainActor public final class RelayAppleBroadcastPipeline<Codec: RelayWireCodec> {
        private weak var host: RelayAppleHost<Codec>?
        private let codec: Codec
        private let starvation: RelayCameraStarvationPolicy
        private let bitratePolicy: RelayBitratePolicy
        private let interval: TimeInterval
        private let projectVideo:
            @MainActor (Codec.FrameMetadata, RelayVideoDescription) -> Codec.FrameMetadata
        private let jpeg: @Sendable (CGImage) -> Data?
        private let now: @MainActor () -> TimeInterval
        private let journal: @Sendable (String) -> Void
        private let makeEncoder: @MainActor (RelayEncoderProfile) -> RelayAppleImageEncoder
        private var encoder: RelayAppleImageEncoder
        private var stages: RelayBroadcastStages
        private var adaptation: WatcherRelayBitrate
        private var lastFrameAt: TimeInterval = 0
        public init(
            host: RelayAppleHost<Codec>, codec: Codec, profile: RelayEncoderProfile,
            starvation: RelayCameraStarvationPolicy, bitratePolicy: RelayBitratePolicy = .init(),
            frameInterval: TimeInterval, encodingDepth: Int = 2, jpegDepth: Int = 2,
            projectVideo:
                @escaping @MainActor (Codec.FrameMetadata, RelayVideoDescription) ->
                Codec.FrameMetadata,
            jpeg: @escaping @Sendable (CGImage) -> Data?,
            now: @escaping @MainActor () -> TimeInterval = { CFAbsoluteTimeGetCurrent() },
            journal: @escaping @Sendable (String) -> Void = { _ in },
            makeEncoder: @escaping @MainActor (RelayEncoderProfile) -> RelayAppleImageEncoder = {
                RelayAppleImageEncoder(profile: $0)
            }
        ) {
            precondition(frameInterval >= 0 && encodingDepth > 0 && jpegDepth > 0)
            self.host = host
            self.codec = codec
            self.starvation = starvation
            self.bitratePolicy = bitratePolicy
            interval = frameInterval
            stages = RelayBroadcastStages(encodingDepth: encodingDepth, jpegDepth: jpegDepth)
            self.projectVideo = projectVideo
            self.jpeg = jpeg
            self.now = now
            self.journal = journal
            self.makeEncoder = makeEncoder
            encoder = makeEncoder(profile)
            adaptation = WatcherRelayBitrate(now: now(), policy: bitratePolicy)
            installKeyframeSink()
        }
        private func installKeyframeSink() {
            host?.onKeyframeNeeded = { [weak self] in
                guard let self, self.stages.isActive else { return }
                self.encoder.requestKeyframe()
            }
        }
        public func adoptProfile(_ profile: RelayEncoderProfile) {
            guard stages.isActive else { return }
            stages.replace()
            encoder.invalidate()
            encoder = makeEncoder(profile)
            host?.adoptProfile(profile)
            adaptation = WatcherRelayBitrate(now: now(), policy: bitratePolicy)
            installKeyframeSink()
        }
        /// Called with actual source retirement. The root owns the camera, this owner retires
        /// relay work only; neither operation issues a camera command or closes that camera.
        public func retireSource() {
            guard stages.isActive else { return }
            stages.replace()
            encoder.invalidate()
            host?.retireSource()
            adaptation = WatcherRelayBitrate(now: now(), policy: bitratePolicy)
        }
        public func close() {
            guard stages.isActive else { return }
            stages.close()
            encoder.invalidate()
            host?.onKeyframeNeeded = nil
        }
        public func submit(
            _ image: CGImage, metadata: Codec.FrameMetadata,
            admission: RelayFrameAdmission, cameraFPS: Double?, soloBaselineFPS: Double
        ) {
            guard
                let host = admitTick(
                    admission: admission, cameraFPS: cameraFPS,
                    soloBaselineFPS: soloBaselineFPS), let ticket = stages.admit(.encoding)
            else { return }
            let stage = stages.token
            let source = host.sourceToken
            let encoder = encoder
            encoder.encode(image) { [weak self, weak host, weak encoder] result in
                Task { @MainActor in
                    guard let self, let host, let encoder, self.stages.admits(stage),
                        self.host === host, host.sourceToken == source, self.encoder === encoder,
                        self.stages.complete(ticket)
                    else { return }
                    guard admission.isCurrent() else { return }
                    guard host.isBroadcasting else { return }
                    if let result {
                        let video = RelayVideoDescription(
                            codec: self.codec.profile.hevcCodec,
                            isKeyframe: result.isKeyframe, parameterSets: result.parameterSets)
                        host.broadcast(
                            frameMetadata: self.projectVideo(metadata, video), image: result.data,
                            admittedSource: source)
                        if host.hasJPEGOnlyPeers {
                            self.submitJPEG(
                                image, metadata: metadata, admission: admission, host: host,
                                source: source, jpegOnly: true)
                        }
                    } else {
                        self.submitJPEG(
                            image, metadata: metadata, admission: admission, host: host,
                            source: source, jpegOnly: false)
                    }
                }
            }
        }
        /// A native picture without a CGImage keeps the deployed JPEG fallback. The bounded OS
        /// conversion arrives as one image port; cadence/queue/source retirement remain here.
        public func submitJPEG(
            metadata: Codec.FrameMetadata, admission: RelayFrameAdmission,
            cameraFPS: Double?, soloBaselineFPS: Double, encode: @escaping @Sendable () -> Data?
        ) {
            guard
                let host = admitTick(
                    admission: admission, cameraFPS: cameraFPS,
                    soloBaselineFPS: soloBaselineFPS)
            else { return }
            submitJPEG(
                metadata: metadata, admission: admission, host: host, source: host.sourceToken,
                jpegOnly: false, encode: encode)
        }
        private func admitTick(
            admission: RelayFrameAdmission, cameraFPS: Double?,
            soloBaselineFPS: Double
        ) -> RelayAppleHost<Codec>? {
            guard stages.isActive, admission.isCurrent(), let host, host.isBroadcasting,
                host.peerCount > 0
            else { return nil }
            let now = now()
            guard now - lastFrameAt >= interval else { return nil }
            lastFrameAt = now
            let peersFull = !host.hasPeerReadyForFrame
            let cameraStarving =
                cameraFPS.map {
                    $0 > 0 && $0 < starvation.threshold(soloBaselineFPS: soloBaselineFPS)
                } ?? false
            if let rate = adaptation.recordTick(
                saturated: peersFull, cameraStarving: cameraStarving, now: now)
            {
                journal(
                    "relay bitrate → \(rate / 1_000_000) Mb/s"
                        + (cameraStarving ? " (camera feed starving)" : ""))
                encoder.setTarget(bitsPerSecond: rate, maxFrameQP: adaptation.maxFrameQP)
            }
            return peersFull ? nil : host
        }
        private func submitJPEG(
            _ image: CGImage, metadata: Codec.FrameMetadata,
            admission: RelayFrameAdmission, host: RelayAppleHost<Codec>, source: UUID,
            jpegOnly: Bool
        ) {
            let encode = jpeg
            submitJPEG(
                metadata: metadata, admission: admission, host: host, source: source,
                jpegOnly: jpegOnly, encode: { encode(image) })
        }
        private func submitJPEG(
            metadata: Codec.FrameMetadata, admission: RelayFrameAdmission,
            host: RelayAppleHost<Codec>, source: UUID, jpegOnly: Bool,
            encode: @escaping @Sendable () -> Data?
        ) {
            guard stages.isActive, admission.isCurrent(), host.sourceToken == source,
                let codecID = codec.profile.jpegCodec,
                let ticket = stages.admit(.jpeg)
            else { return }
            let stage = stages.token
            Task { [weak self, weak host] in
                let picture = await Task.detached(priority: .utility) { encode() }.value
                guard let self, let host, self.stages.admits(stage), self.host === host,
                    host.sourceToken == source, self.stages.complete(ticket),
                    host.isBroadcasting, admission.isCurrent(), let picture
                else { return }
                let video = RelayVideoDescription(
                    codec: codecID, isKeyframe: true, parameterSets: nil)
                let projected = projectVideo(metadata, video)
                if jpegOnly {
                    host.broadcastJPEGFallback(
                        frameMetadata: projected, image: picture, admittedSource: source)
                } else {
                    host.broadcast(frameMetadata: projected, image: picture, admittedSource: source)
                }
            }
        }
    }
#endif
