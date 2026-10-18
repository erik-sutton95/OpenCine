#if DEBUG && canImport(AVFoundation) && !os(watchOS)
    import AVFoundation
    import Foundation
    import OpenCineApple
    import Testing

    @Suite struct ReviewClipTests {
        @Test(arguments: ["Review.MOV", "Review.MP4"])
        func writesAPlayableSecondOfVideo(_ name: String) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent(name)
            try await ReviewClip.write(to: url)
            let asset = AVURLAsset(url: url)
            #expect(try await asset.load(.isPlayable))
            #expect(try await asset.load(.duration).seconds == Double(ReviewClip.seconds))
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            #expect(try await track.load(.naturalSize) == CGSize(width: 640, height: 360))
        }
    }
#endif
