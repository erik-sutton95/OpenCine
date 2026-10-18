#if canImport(AVFoundation) && !os(watchOS) && DEBUG
    import AVFoundation
    import CoreVideo
    import Foundation

    /// The movie every app's Debug review harness stages as a SIMULATED clip (`ReviewLaunch`), so
    /// no review or conformance scenario depends on footage outside the repository. Compiled out of
    /// Release builds.
    public enum ReviewClip {
        public static let seconds = 1
        public static let size = (width: 640, height: 360)

        /// Writes one second of 24 fps H.264 grey frames; QuickTime unless the name ends in `.mp4`.
        public static func write(to url: URL) async throws {
            try? FileManager.default.removeItem(at: url)
            let type: AVFileType = url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
            let writer = try AVAssetWriter(outputURL: url, fileType: type)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width,
                    AVVideoHeightKey: size.height,
                ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
                ])
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<(24 * seconds) {
                // ponytail: polls readiness; a 24-frame write never waits long.
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw CocoaError(.fileWriteUnknown) }
                CVPixelBufferLockBaseAddress(buffer, [])
                memset(
                    CVPixelBufferGetBaseAddress(buffer), Int32(64 + frame * 4),
                    CVPixelBufferGetDataSize(buffer))
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 24))
                else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: CMTimeValue(24 * seconds), timescale: 24))
            // The async `finishWriting()` overload crashes resuming its continuation under the
            // Swift 6 runtime on macOS 26 (swiftpm-testing-helper, 2026-10-12); the handler form does not.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                writer.finishWriting { done.resume() }
            }
            guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        }
    }
#endif
