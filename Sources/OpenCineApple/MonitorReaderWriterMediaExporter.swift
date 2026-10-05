#if canImport(AVFoundation) && canImport(CoreImage) && !os(watchOS)
    import AVFoundation
    import CoreImage
    import CoreMedia
    import CoreVideo
    import Foundation
    import OpenCineMedia
    import os

    /// Exports the readable part of a movie with separate native video and audio readers.
    /// The app prepares its destination and sampled cube; this owner runs the native operation.
    public enum MonitorReaderWriterMediaExporter {
        public typealias Format = MonitorMediaExporter.Format
        public typealias ExportResult = MonitorMediaExporter.ExportResult
        public typealias ExportError = MonitorMediaExporter.ExportError

        public static func export<Metadata: Encodable & Sendable>(
            sourceURL: URL, outputURL: URL, format: Format, cube: CubeLUT? = nil,
            metadata: Metadata?, diagnostics: @escaping @Sendable (String) -> Void = { _ in },
            timecodeDiagnostics: (@Sendable (MonitorMovieTimecode.Diagnostic) -> Void)? = nil,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws -> ExportResult {
            try await Operation(trace: diagnostics).export(
                sourceURL: sourceURL, outputURL: outputURL, format: format, cube: cube,
                metadata: metadata, timecodeDiagnostics: timecodeDiagnostics, progress: progress)
        }

        /// Builds a video/audio composition without source data tracks.
        public static func audioVisualExportAsset(
            from asset: AVAsset, diagnostics: @escaping @Sendable (String) -> Void = { _ in }
        ) async throws
            -> AVMutableComposition
        {
            try await Operation(trace: diagnostics).audioVisualExportAsset(from: asset)
        }

        private struct Operation: Sendable {
            let trace: @Sendable (String) -> Void
            private var renderContext: CIContext {
                MonitorMediaExporter.colorContext(preservingEncodedValues: false)
            }
            private func describe(_ error: Error) -> String {
                let ns = error as NSError
                return "\(ns.domain) code=\(ns.code) \(ns.localizedDescription)"
            }

            func export<Metadata: Encodable & Sendable>(
                sourceURL: URL,
                outputURL: URL,
                format: Format,
                cube: CubeLUT?,
                metadata: Metadata?,
                timecodeDiagnostics: (@Sendable (MonitorMovieTimecode.Diagnostic) -> Void)?,
                progress: @escaping @Sendable (Double) -> Void
            ) async throws -> ExportResult {
                progress(0.02)
                trace(
                    "export start source=\(sourceURL.lastPathComponent) format=\(format.rawValue) bake=\(cube != nil) dest=\(outputURL.lastPathComponent)"
                )

                let truncated = MonitorMovieFile.mediaDataExtendsPastEndOfFile(at: sourceURL)
                if truncated {
                    trace("source mdat extends past EOF; exporting readable media only")
                }
                let passthrough =
                    cube == nil
                    && !truncated
                    && canPassthroughCopy(
                        sourceURL: sourceURL, outputURL: outputURL, format: format)
                if passthrough {
                    trace("export path=passthrough-copy")
                    try FileManager.default.copyItem(at: sourceURL, to: outputURL)
                    progress(0.9)
                } else {
                    trace("export path=reader-writer")
                    do {
                        try await transcode(
                            sourceURL: sourceURL, outputURL: outputURL, format: format, cube: cube,
                            progress: progress)
                    } catch {
                        trace("transcode failed \(describe(error))")
                        throw mappedExportError(error)
                    }
                }

                try await ensureFileReady(at: outputURL)
                guard MonitorMovieFile.movieHasFinishedHeader(at: outputURL) else {
                    trace("export missing moov header")
                    throw ExportError.failed("export file is incomplete")
                }

                if !passthrough {
                    await MonitorMovieTimecode.copySourceTimecodeTrack(
                        from: sourceURL, to: outputURL, as: format.avFileType,
                        diagnostics: { diagnostic in
                            if let timecodeDiagnostics {
                                timecodeDiagnostics(diagnostic)
                            } else {
                                trace(diagnostic.message)
                            }
                        })
                    if !MonitorMovieFile.movieHasFinishedHeader(at: outputURL) {
                        trace("timecode embed left an incomplete movie")
                        throw ExportError.failed("export file is incomplete")
                    }
                }

                let metadataURL = try writeMetadataSidecar(metadata, nextTo: outputURL)
                progress(1.0)
                let size =
                    (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]
                        as? UInt64)
                    ?? 0
                trace("export done file=\(outputURL.lastPathComponent) bytes=\(size)")
                return ExportResult(videoURL: outputURL, metadataURL: metadataURL)
            }

            private func canPassthroughCopy(
                sourceURL: URL, outputURL: URL, format: Format
            ) -> Bool {
                let sourceExt = sourceURL.pathExtension.lowercased()
                let targetExt = format.rawValue
                guard sourceExt == targetExt || (sourceExt == "m4v" && targetExt == "mp4") else {
                    return false
                }
                return sourceURL.standardizedFileURL != outputURL.standardizedFileURL
            }

            /// Video+audio composition of `asset`, dropping `tmcd` and other data tracks.
            ///
            /// A source can carry a per-frame QuickTime timecode track. Feeding that original asset
            /// to `AVAssetExportSession` fails on iOS with `AVErrorInvalidSampleCursor` (−11880), which
            /// is why native Share and Save to Photos both died on the same export path.
            func audioVisualExportAsset(from asset: AVAsset) async throws -> AVMutableComposition {
                let composition = AVMutableComposition()
                let duration = try await asset.load(.duration)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                let timecodeTracks = try await asset.loadTracks(withMediaType: .timecode)
                trace(
                    "source tracks video=\(videoTracks.count) audio=\(audioTracks.count) tmcd=\(timecodeTracks.count) duration=\(duration.seconds)"
                )
                guard !videoTracks.isEmpty else { throw ExportError.sessionSetupFailed }

                for track in videoTracks {
                    guard
                        let dest = composition.addMutableTrack(
                            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                    else { continue }
                    do {
                        try insert(
                            track, timeRange: try await track.load(.timeRange), into: dest,
                            fallbackDuration: duration)
                        dest.preferredTransform = try await track.load(.preferredTransform)
                    } catch {
                        trace(
                            "video insert failed: \(describe(error))")
                        composition.removeTrack(dest)
                    }
                }
                guard !(try await composition.loadTracks(withMediaType: .video)).isEmpty else {
                    throw ExportError.sessionSetupFailed
                }

                for track in audioTracks {
                    guard
                        let dest = composition.addMutableTrack(
                            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    else { continue }
                    do {
                        try insert(
                            track, timeRange: try await track.load(.timeRange), into: dest,
                            fallbackDuration: duration)
                    } catch {
                        trace(
                            "audio insert failed: \(describe(error))")
                        composition.removeTrack(dest)
                    }
                }
                return composition
            }

            private func insert(
                _ source: AVAssetTrack,
                timeRange: CMTimeRange,
                into dest: AVMutableCompositionTrack,
                fallbackDuration: CMTime
            ) throws {
                do {
                    try dest.insertTimeRange(timeRange, of: source, at: .zero)
                } catch {
                    try dest.insertTimeRange(
                        CMTimeRange(start: .zero, duration: fallbackDuration), of: source, at: .zero
                    )
                }
            }

            private func transcode(
                sourceURL: URL,
                outputURL: URL,
                format: Format,
                cube: CubeLUT?,
                progress: @escaping @Sendable (Double) -> Void
            ) async throws {
                // Sources can carry a complete `moov` whose `mdat`
                // was cut off (edit list + truncated media). `AVAssetReader` then throws
                // `AVErrorInvalidSampleCursor` (−11880) at the first missing sample. Treating that
                // as end-of-readable-media and calling `finishWriting` yields a playable file;
                // throwing leaves `mdat` size 0 and Photos/Share surface "Invalid sample cursor".
                progress(0.05)
                trace("reader/writer start")
                try await transcodeWithReaderWriter(
                    sourceURL: sourceURL, outputURL: outputURL, format: format, cube: cube,
                    progress: progress)
                trace("reader/writer completed")
                progress(0.95)
            }

            private func isInvalidSampleCursor(_ error: Error) -> Bool {
                let ns = error as NSError
                return ns.domain == AVFoundationErrorDomain
                    && ns.code == AVError.Code.invalidSampleCursor.rawValue
            }

            private func mappedExportError(_ error: Error) -> Error {
                if isInvalidSampleCursor(error) {
                    return ExportError.failed("this clip's media data is unreadable")
                }
                return error
            }

            private func isEndOfReadableMedia(_ reader: AVAssetReader, samples: Int) -> Bool {
                switch reader.status {
                case .completed, .cancelled:
                    return true
                case .failed:
                    if let error = reader.error, isInvalidSampleCursor(error) {
                        return true
                    }
                    return samples > 0
                default:
                    return false
                }
            }

            /// `copyNextSampleBuffer` can block forever on a truncated `mdat`. Time out and cancel
            /// the reader so `finishWriting` can still emit a playable file.
            private static let sampleCopyQueue = DispatchQueue(
                label: "opencine.media-export.copy", attributes: .concurrent)

            private final class SampleCopyBox: Sendable {
                // Cancellation can outlast the second semaphore wait. Protect a late
                // copy publication and its concurrent read without changing either timeout.
                private let state = OSAllocatedUnfairLock<CMSampleBuffer?>(uncheckedState: nil)
                var sample: CMSampleBuffer? {
                    get { state.withLockUnchecked { $0 } }
                    set { state.withLockUnchecked { $0 = newValue } }
                }
            }

            private func copyNextSample(
                from output: AVAssetReaderTrackOutput,
                reader: AVAssetReader,
                timeout: TimeInterval = 8
            ) -> CMSampleBuffer? {
                let box = SampleCopyBox()
                let lock = DispatchSemaphore(value: 0)
                nonisolated(unsafe) let trackOutput = output
                Self.sampleCopyQueue.async {
                    box.sample = trackOutput.copyNextSampleBuffer()
                    lock.signal()
                }
                if lock.wait(timeout: .now() + timeout) == .timedOut {
                    reader.cancelReading()
                    _ = lock.wait(timeout: .now() + 1)
                    trace("copyNext timed out status=\(reader.status.rawValue)")
                }
                return box.sample
            }

            private func transcodeWithReaderWriter(
                sourceURL: URL,
                outputURL: URL,
                format: Format,
                cube: CubeLUT?,
                progress: @escaping @Sendable (Double) -> Void
            ) async throws {
                let asset = AVURLAsset(
                    url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first
                else {
                    throw ExportError.sessionSetupFailed
                }
                let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
                let naturalSize = try await videoTrack.load(.naturalSize)
                let transform = try await videoTrack.load(.preferredTransform)
                // Encode in the track's coded size and stamp `preferredTransform`. Using the
                // display size *and* the transform double-rotates sources that carry ±90°.
                let width = max(16, Int(abs(naturalSize.width).rounded()))
                let height = max(16, Int(abs(naturalSize.height).rounded()))
                let duration = try await asset.load(.duration)
                let progressDuration = MonitorMovieFile.scaledProgressDuration(
                    for: sourceURL, headerDuration: duration)
                trace(
                    "reader tracks coded=\(width)x\(height) duration=\(duration.seconds) progressDuration=\(progressDuration.seconds) audio=\(audioTrack != nil)"
                )

                let videoReader = try AVAssetReader(asset: asset)
                let videoOutput = AVAssetReaderTrackOutput(
                    track: videoTrack,
                    outputSettings: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                    ])
                videoOutput.alwaysCopiesSampleData = true
                guard videoReader.canAdd(videoOutput) else { throw ExportError.sessionSetupFailed }
                videoReader.add(videoOutput)

                var audioReader: AVAssetReader?
                var audioOutput: AVAssetReaderTrackOutput?
                if let audioTrack {
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(
                        track: audioTrack, outputSettings: audioPCMSettings())
                    output.alwaysCopiesSampleData = true
                    if reader.canAdd(output) {
                        reader.add(output)
                        audioReader = reader
                        audioOutput = output
                    }
                }

                let writer = try AVAssetWriter(outputURL: outputURL, fileType: format.avFileType)
                let videoInput = AVAssetWriterInput(
                    mediaType: .video,
                    outputSettings: [
                        AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoWidthKey: width,
                        AVVideoHeightKey: height,
                    ])
                videoInput.expectsMediaDataInRealTime = false
                videoInput.transform = transform
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: videoInput,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: width,
                        kCVPixelBufferHeightKey as String: height,
                    ])
                guard writer.canAdd(videoInput) else { throw ExportError.sessionSetupFailed }
                writer.add(videoInput)

                var audioInput: AVAssetWriterInput?
                if audioOutput != nil, let audioTrack {
                    let input = AVAssetWriterInput(
                        mediaType: .audio, outputSettings: await audioAACSettings(for: audioTrack))
                    input.expectsMediaDataInRealTime = false
                    if writer.canAdd(input) {
                        writer.add(input)
                        audioInput = input
                    }
                }

                guard writer.startWriting() else {
                    throw writer.error ?? ExportError.sessionSetupFailed
                }
                guard videoReader.startReading() else {
                    throw mappedExportError(videoReader.error ?? ExportError.sessionSetupFailed)
                }
                if let audioReader, !audioReader.startReading() {
                    trace("audio reader skipped \(audioReader.error.map(describe) ?? "nil")")
                    audioInput?.markAsFinished()
                    audioInput = nil
                    audioOutput = nil
                }

                let filter = cube.flatMap(colorCubeFilter(for:))
                let stats: ReaderWriterStats
                do {
                    stats = try await appendReaderWriterSamples(
                        videoReader: videoReader,
                        videoOutput: videoOutput,
                        videoInput: videoInput,
                        adaptor: adaptor,
                        audioReader: audioReader,
                        audioOutput: audioOutput,
                        audioInput: audioInput,
                        writer: writer,
                        filter: filter,
                        duration: progressDuration,
                        progress: progress)
                } catch {
                    trace("pump threw \(describe(error)); cancelling writer")
                    videoInput.markAsFinished()
                    audioInput?.markAsFinished()
                    writer.cancelWriting()
                    throw error
                }

                progress(0.9)
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    writer.finishWriting { continuation.resume() }
                }
                guard writer.status == .completed, stats.videoFrames > 0 else {
                    trace(
                        "writer failed status=\(writer.status.rawValue) video=\(stats.videoFrames) \(writer.error.map(describe) ?? "nil")"
                    )
                    try? FileManager.default.removeItem(at: outputURL)
                    throw writer.error
                        ?? mappedExportError(
                            videoReader.error ?? ExportError.failed("export"))
                }
                trace(
                    "writer finished frames=\(stats.videoFrames) audio=\(stats.audioSamples) lastPTS=\(stats.lastVideoPTS.seconds) truncated=\(stats.endedEarly)"
                )
            }

            private func colorCubeFilter(for cube: CubeLUT) -> CIFilter? {
                let prepared = cube
                let cubeData = prepared.rgbaComponents.withUnsafeBytes { Data($0) }
                return CIFilter(
                    name: "CIColorCube",
                    parameters: [
                        "inputCubeDimension": prepared.size,
                        "inputCubeData": cubeData,
                    ])
            }

            private struct ReaderWriterStats {
                var videoFrames = 0
                var audioSamples = 0
                var lastVideoPTS = CMTime.zero
                var endedEarly = false
                var sessionStarted = false
            }

            private func audioPCMSettings() -> [String: Any] {
                [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            }

            private func audioAACSettings(for track: AVAssetTrack) async -> [String: Any] {
                var sampleRate = 48_000.0
                var channels = 2
                if let format = try? await track.load(.formatDescriptions).first,
                    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
                {
                    if asbd.mSampleRate > 0 { sampleRate = asbd.mSampleRate }
                    if asbd.mChannelsPerFrame > 0 { channels = Int(asbd.mChannelsPerFrame) }
                }
                return [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: 192_000,
                ]
            }

            private func appendReaderWriterSamples(
                videoReader: AVAssetReader,
                videoOutput: AVAssetReaderTrackOutput,
                videoInput: AVAssetWriterInput,
                adaptor: AVAssetWriterInputPixelBufferAdaptor,
                audioReader: AVAssetReader?,
                audioOutput: AVAssetReaderTrackOutput?,
                audioInput: AVAssetWriterInput?,
                writer: AVAssetWriter,
                filter: CIFilter?,
                duration: CMTime,
                progress: @escaping @Sendable (Double) -> Void
            ) async throws -> ReaderWriterStats {
                var stats = ReaderWriterStats()
                var videoDone = false
                var audioDone = audioOutput == nil || audioInput == nil
                var idleSpins = 0
                while !videoDone || !audioDone {
                    if Task.isCancelled {
                        videoReader.cancelReading()
                        audioReader?.cancelReading()
                        writer.cancelWriting()
                        throw CancellationError()
                    }
                    var progressed = false
                    if !videoDone {
                        let videoReady = videoInput.isReadyForMoreMediaData
                        let videoReaderStopped =
                            videoReader.status == .failed || videoReader.status == .completed
                            || videoReader.status == .cancelled
                        if videoReady {
                            if let sample = copyNextSample(from: videoOutput, reader: videoReader) {
                                startWriterSessionIfNeeded(
                                    writer, stats: &stats,
                                    at: CMSampleBufferGetPresentationTimeStamp(sample))
                                try appendVideoSample(sample, adaptor: adaptor, filter: filter)
                                stats.videoFrames += 1
                                stats.lastVideoPTS = CMSampleBufferGetPresentationTimeStamp(sample)
                                if duration.seconds > 0, stats.lastVideoPTS.seconds > 0 {
                                    let fraction = stats.lastVideoPTS.seconds / duration.seconds
                                    progress(min(0.9, 0.05 + 0.85 * fraction))
                                }
                                progressed = true
                            } else if isEndOfReadableMedia(videoReader, samples: stats.videoFrames)
                            {
                                if videoReader.status == .failed {
                                    stats.endedEarly = true
                                    trace(
                                        "video readable-end frames=\(stats.videoFrames) \(videoReader.error.map(describe) ?? "nil")"
                                    )
                                    progress(0.9)
                                }
                                videoDone = true
                                progressed = true
                            } else if videoReaderStopped {
                                videoDone = true
                                progressed = true
                            }
                        } else if videoReaderStopped {
                            videoDone = true
                            progressed = true
                        }
                    }
                    if !audioDone, let audioOutput, let audioInput, let audioReader {
                        let audioReady = audioInput.isReadyForMoreMediaData
                        let audioReaderStopped =
                            audioReader.status == .failed || audioReader.status == .completed
                            || audioReader.status == .cancelled
                        if audioReady {
                            if let sample = copyNextSample(from: audioOutput, reader: audioReader) {
                                startWriterSessionIfNeeded(
                                    writer, stats: &stats,
                                    at: CMSampleBufferGetPresentationTimeStamp(sample))
                                if audioInput.append(sample) {
                                    stats.audioSamples += 1
                                    progressed = true
                                } else {
                                    trace(
                                        "audio append stopped \(writer.error.map(describe) ?? "nil")"
                                    )
                                    audioDone = true
                                    progressed = true
                                }
                            } else if isEndOfReadableMedia(audioReader, samples: stats.audioSamples)
                            {
                                if audioReader.status == .failed {
                                    stats.endedEarly = true
                                    trace(
                                        "audio readable-end samples=\(stats.audioSamples) \(audioReader.error.map(describe) ?? "nil")"
                                    )
                                }
                                audioDone = true
                                progressed = true
                            } else if audioReaderStopped {
                                audioDone = true
                                progressed = true
                            }
                        } else if audioReaderStopped {
                            audioDone = true
                            progressed = true
                        }
                    }
                    if writer.status == .failed {
                        throw writer.error ?? ExportError.failed("export")
                    }
                    if !progressed {
                        idleSpins += 1
                        // Writer back-pressure plus a failed reader used to spin forever and
                        // never `finishWriting`. After ~500ms with no progress, drop a stopped track.
                        if idleSpins == 50 {
                            if !videoDone,
                                videoReader.status == .failed || videoReader.status == .completed
                            {
                                videoDone = true
                                stats.endedEarly = true
                                trace("video idle-stop frames=\(stats.videoFrames)")
                            }
                            if !audioDone,
                                let audioReader,
                                audioReader.status == .failed || audioReader.status == .completed
                            {
                                audioDone = true
                                stats.endedEarly = true
                                trace("audio idle-stop samples=\(stats.audioSamples)")
                            }
                        }
                        if idleSpins >= 500, stats.videoFrames > 0 {
                            videoDone = true
                            audioDone = true
                            stats.endedEarly = true
                            trace(
                                "idle timeout frames=\(stats.videoFrames) audio=\(stats.audioSamples)"
                            )
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    } else {
                        idleSpins = 0
                    }
                }
                if stats.videoFrames == 0 {
                    // No decoded frame is a refusal whatever the reader reports: a cut-off
                    // sample (-11880) and undecodable data (-11821) both mean an unreadable clip.
                    trace("no decoded video \(videoReader.error.map(describe) ?? "nil")")
                    throw ExportError.failed("this clip's media data is unreadable")
                }
                return stats
            }

            private func startWriterSessionIfNeeded(
                _ writer: AVAssetWriter, stats: inout ReaderWriterStats, at time: CMTime
            ) {
                guard !stats.sessionStarted else { return }
                writer.startSession(atSourceTime: time)
                stats.sessionStarted = true
            }

            private func appendVideoSample(
                _ sample: CMSampleBuffer,
                adaptor: AVAssetWriterInputPixelBufferAdaptor,
                filter: CIFilter?
            ) throws {
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                    throw ExportError.failed("video")
                }
                if let filter {
                    let source = CIImage(cvPixelBuffer: pixelBuffer)
                    filter.setValue(source.clampedToExtent(), forKey: kCIInputImageKey)
                    let output = (filter.outputImage ?? source).cropped(to: source.extent)
                    var rendered: CVPixelBuffer?
                    if let pool = adaptor.pixelBufferPool {
                        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &rendered)
                    }
                    if rendered == nil {
                        let width = CVPixelBufferGetWidth(pixelBuffer)
                        let height = CVPixelBufferGetHeight(pixelBuffer)
                        CVPixelBufferCreate(
                            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil,
                            &rendered)
                    }
                    guard let rendered else { throw ExportError.failed("pixel buffer") }
                    renderContext.render(output, to: rendered)
                    if !adaptor.append(rendered, withPresentationTime: timestamp) {
                        throw ExportError.failed("video")
                    }
                    return
                }
                if !adaptor.append(pixelBuffer, withPresentationTime: timestamp) {
                    throw ExportError.failed("video")
                }
            }

            private func writeMetadataSidecar<Metadata: Encodable & Sendable>(
                _ metadata: Metadata?, nextTo videoURL: URL
            ) throws -> URL? {
                guard let metadata else { return nil }
                let url = videoURL.deletingPathExtension().appendingPathExtension("meta.json")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(metadata)
                try data.write(to: url, options: .atomic)
                return url
            }

            /// Waits briefly for AVFoundation / copy writes to become readable on disk.
            private func ensureFileReady(at url: URL) async throws {
                for _ in 0..<20 {
                    if FileManager.default.fileExists(atPath: url.path),
                        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                        let size = attrs[.size] as? UInt64, size > 0
                    {
                        return
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
                throw ExportError.failed("export file not available")
            }
        }
    }
#endif
