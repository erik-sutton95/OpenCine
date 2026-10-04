#if canImport(AVFoundation) && !os(watchOS)
    import AVFoundation
    import CoreMedia
    import Foundation

    /// Copies a source clip's QuickTime timecode (`tmcd`) track into a finished export.
    ///
    /// The track's format description and frame-number samples preserve its start value,
    /// frame quanta and drop-frame flags. Native transcoding does not reconstruct that data.
    public enum MonitorMovieTimecode {
        public struct Diagnostic: Sendable {
            public enum Level: Sendable {
                case information
                case error
            }

            public let level: Level
            public let message: String

            public init(level: Level, message: String) {
                self.level = level
                self.message = message
            }
        }

        /// Best-effort: appends `sourceURL`'s timecode track to the finished export at `outputURL`
        /// in place (sample data + rewritten moov appended to the file). No-ops when the source has
        /// no timecode track; never throws - a missing timecode must not fail a delivery.
        public static func copySourceTimecodeTrack(
            from sourceURL: URL, to outputURL: URL, as fileType: AVFileType,
            diagnostics: @escaping @Sendable (Diagnostic) -> Void = { _ in }
        ) async {
            func report(_ level: Diagnostic.Level, _ message: String) {
                diagnostics(Diagnostic(level: level, message: message))
            }
            // Precise timing is required for cross-asset track inserts (AVFoundation -11838 / -11880).
            let source = AVURLAsset(
                url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let stagedURL = outputURL.deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(outputURL.deletingPathExtension().lastPathComponent).tmcd"
                )
                .appendingPathExtension(outputURL.pathExtension)
            do {
                if MonitorMovieFile.mediaDataExtendsPastEndOfFile(at: sourceURL) {
                    report(.information, "timecode embed skipped: source mdat is truncated")
                    return
                }
                guard let sourceTrack = try await source.loadTracks(withMediaType: .timecode).first
                else {
                    report(.information, "timecode embed skipped: source has no tmcd track")
                    return
                }
                let sourceRange = try await sourceTrack.load(.timeRange)
                let destDuration = try await AVURLAsset(
                    url: outputURL,
                    options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
                ).load(.duration)
                let timeRange: CMTimeRange
                if destDuration.isNumeric, destDuration < sourceRange.duration {
                    timeRange = CMTimeRange(start: sourceRange.start, duration: destDuration)
                } else {
                    timeRange = sourceRange
                }

                try? FileManager.default.removeItem(at: stagedURL)
                try FileManager.default.copyItem(at: outputURL, to: stagedURL)
                defer { try? FileManager.default.removeItem(at: stagedURL) }

                let movie = AVMutableMovie(url: stagedURL, options: nil)
                movie.defaultMediaDataStorage = AVMediaDataStorage(url: stagedURL, options: nil)
                guard
                    let timecodeTrack = movie.addMutableTrack(
                        withMediaType: .timecode, copySettingsFrom: nil)
                else {
                    report(.error, "timecode embed: cannot add tmcd track to export")
                    return
                }
                try timecodeTrack.insertTimeRange(
                    timeRange, of: sourceTrack, at: .zero, copySampleData: true)
                if let video = try await movie.loadTracks(withMediaType: .video).first {
                    video.addTrackAssociation(to: timecodeTrack, type: .timecode)
                }
                try movie.writeHeader(
                    to: stagedURL, fileType: fileType, options: .addMovieHeaderToDestination)
                guard MonitorMovieFile.movieHasFinishedHeader(at: stagedURL) else {
                    report(
                        .error, "timecode embed produced a file without moov; keeping the export")
                    return
                }
                try FileManager.default.removeItem(at: outputURL)
                try FileManager.default.copyItem(at: stagedURL, to: outputURL)
                report(.information, "timecode embed succeeded")
            } catch {
                let ns = error as NSError
                report(
                    .error,
                    "timecode embed failed: \(ns.domain) code=\(ns.code) \(ns.localizedDescription)"
                )
            }
        }

    }
#endif
