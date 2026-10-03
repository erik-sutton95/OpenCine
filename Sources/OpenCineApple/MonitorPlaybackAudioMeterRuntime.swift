#if os(iOS)
    import AVFoundation
    import Accelerate
    import MediaToolbox
    import os
    import OpenCineMedia

    /// Lock-guarded per-channel linear peak accumulator shared between the `MTAudioProcessingTap`
    /// render-thread callbacks and the main-actor polling loop.
    private final class MonitorAudioTapContext: @unchecked Sendable {
        let source: MonitorAudioPeakLease
        init(source: MonitorAudioPeakLease) { self.source = source }
        private struct State {
            var writer: MonitorAudioPeakWriter?
            var isFloat32 = false
            var isInterleaved = false
            var channelCount = 0
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func setFormat(_ description: AudioStreamBasicDescription) {
            let writer = source.prepare()
            state.withLock {
                $0.writer = writer
                $0.isFloat32 =
                    description.mFormatID == kAudioFormatLinearPCM
                    && description.mFormatFlags & kAudioFormatFlagIsFloat != 0
                    && description.mBitsPerChannel == 32
                $0.isInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                $0.channelCount = Int(description.mChannelsPerFrame)
            }
        }

        var format:
            (
                isFloat32: Bool, isInterleaved: Bool, channelCount: Int,
                writer: MonitorAudioPeakWriter?
            )
        {
            state.withLock { ($0.isFloat32, $0.isInterleaved, $0.channelCount, $0.writer) }
        }

    }

    private enum MonitorAudioLevelTapFactory {
        static func makeTap(source: MonitorAudioPeakLease, onFailure: @Sendable (Int32) -> Void)
            -> MTAudioProcessingTap?
        {
            let box = MonitorAudioTapContext(source: source)
            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque()),
                init: { _, clientInfo, tapStorageOut in
                    tapStorageOut.pointee = clientInfo
                },
                finalize: { tap in
                    let context = Unmanaged<MonitorAudioTapContext>.fromOpaque(
                        MTAudioProcessingTapGetStorage(tap))
                    context.takeUnretainedValue().source.close()
                    context.release()
                },
                prepare: { tap, _, processingFormat in
                    Unmanaged<MonitorAudioTapContext>.fromOpaque(
                        MTAudioProcessingTapGetStorage(tap)
                    )
                    .takeUnretainedValue()
                    .setFormat(processingFormat.pointee)
                },
                unprepare: nil,
                process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                    let status = MTAudioProcessingTapGetSourceAudio(
                        tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                    guard status == noErr else { return }
                    let box = Unmanaged<MonitorAudioTapContext>
                        .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                        .takeUnretainedValue()
                    guard box.source.isActive else { return }
                    let format = box.format
                    guard format.isFloat32, let writer = format.writer, writer.isActive else {
                        return
                    }
                    let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
                    var left: Float = 0
                    var right: Float = 0
                    if format.isInterleaved, let buffer = buffers.first, let data = buffer.mData {
                        let channels = max(1, format.channelCount)
                        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                        let frames = sampleCount / channels
                        guard frames > 0 else { return }
                        let samples = data.assumingMemoryBound(to: Float.self)
                        vDSP_maxmgv(samples, vDSP_Stride(channels), &left, vDSP_Length(frames))
                        if channels > 1 {
                            vDSP_maxmgv(
                                samples + 1, vDSP_Stride(channels), &right, vDSP_Length(frames))
                        } else {
                            right = left
                        }
                    } else {
                        for (index, buffer) in buffers.enumerated() where index < 2 {
                            guard let data = buffer.mData else { continue }
                            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                            guard count > 0 else { continue }
                            var peak: Float = 0
                            vDSP_maxmgv(
                                data.assumingMemoryBound(to: Float.self), 1, &peak,
                                vDSP_Length(count))
                            if index == 0 { left = peak } else { right = peak }
                        }
                        if buffers.count < 2 { right = left }
                    }
                    writer.ingest(left: left, right: right)
                }
            )
            var tap: MTAudioProcessingTap?
            let status = MTAudioProcessingTapCreate(
                kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap
            )
            guard status == noErr, let tap else {
                Unmanaged.passUnretained(box).release()
                source.close()
                onFailure(status)
                return nil
            }
            return tap
        }
    }

    /// Actual tap attachment and meter polling owner; application audio-session policy stays outside.
    @MainActor public final class MonitorPlaybackAudioMeterRuntime {
        private let peaks = MonitorAudioPeakAccumulator()
        private lazy var sampler = MonitorAudioMeterSampler(owner: peaks)
        private let onTapFailure: @Sendable (Int32) -> Void
        private var source: MonitorAudioPeakLease?
        private var attachTask: Task<Void, Never>?
        private var pollTask: Task<Void, Never>?

        public init(onTapFailure: @escaping @Sendable (Int32) -> Void = { _ in }) {
            self.onTapFailure = onTapFailure
        }

        public func attach(to item: AVPlayerItem) {
            attachTask?.cancel()
            source?.close()
            guard let lease = peaks.beginSource() else { return }
            source = lease
            attachTask = Task { @MainActor [weak self, weak item] in
                guard let self, let item, !Task.isCancelled, lease.isActive else { return }
                guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first
                else { return }
                guard !Task.isCancelled, lease.isActive else { return }
                guard
                    let tap = MonitorAudioLevelTapFactory.makeTap(
                        source: lease, onFailure: self.onTapFailure)
                else { return }
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.audioTapProcessor = tap
                let mix = AVMutableAudioMix()
                mix.inputParameters = [parameters]
                item.audioMix = mix
            }
        }

        public func detach(from item: AVPlayerItem?) {
            attachTask?.cancel()
            attachTask = nil
            source?.close()
            source = nil
            item?.audioMix = nil
        }

        public func startPolling(onLevels: @escaping @MainActor (MonitorAudioMeterLevels?) -> Void)
        {
            pollTask?.cancel()
            sampler.reset()
            let sampler = sampler
            pollTask = Task { @MainActor [sampler] in
                var lastTick = CFAbsoluteTimeGetCurrent()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(42))
                    if Task.isCancelled { return }
                    let now = CFAbsoluteTimeGetCurrent()
                    let dt = now - lastTick
                    lastTick = now
                    onLevels(sampler.step(dt: dt))
                }
            }
        }
        public func stopPolling() {
            pollTask?.cancel()
            pollTask = nil
        }
        public func close() {
            attachTask?.cancel()
            attachTask = nil
            stopPolling()
            source?.close()
            source = nil
            peaks.close()
        }
        deinit {
            attachTask?.cancel()
            pollTask?.cancel()
            peaks.close()
        }
    }
#endif
