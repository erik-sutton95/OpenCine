#if DEBUG
    import Foundation
    @testable import Insta360Apple
    import Insta360Protocol
    import OpenCineCore
    import OpenCineMedia
    import Testing

    /// The review camera behind the backend's link: the real session, media service and browse run
    /// over it, its clips arrive deletable with their facts, and every other command is refused.
    @MainActor struct LunaReviewCameraTests {
        let clip = LunaReviewCamera.Clip(
            uri: "/DCIM/Camera01/VID_20260912_120000_00_001.MP4", byteCount: 4096, milliseconds: 1000,
            width: 640, height: 360, fps: 24, stamp: 20_260_912_120_000)

        @Test func theRealMediaServiceListsAndDeletesTheReviewClips() async throws {
            let camera = LunaReviewCamera(clips: [clip])
            let backend = LunaCameraBackend(useExistingNetwork: true)
            #expect(!backend.isControlReady)
            backend.connect(review: camera)
            #expect(backend.isControlReady)
            let session = backend.openSession()
            #expect(session.admitsControl)
            let media = try #require(backend.mediaService(for: session.id))
            let browse = try await media.openBrowse()
            let delta = try #require(try await browse.catalog().next())
            let asset = try #require(delta.upserts.first)
            #expect(delta.upserts.count == 1)
            #expect(asset.deletable == true)
            #expect(asset.filename == "VID_20260912_120000_00_001.MP4")
            #expect(asset.kind == .video)
            #expect(asset.durationSeconds == 1)
            #expect(asset.frameRate == 24)
            #expect(asset.pixelSize == MediaPixelSize(width: 640, height: 360))
            #expect(asset.representations.first?.byteCount == 4096)
            #expect(backend.mediaCatalogRecord(asset.id, binding: browse.binding)?.file.uri == clip.uri)

            let results = try await #require(browse.deletion).delete([asset.id])
            #expect(results.map(\.outcome) == [.accepted])
            #expect(camera.clips.isEmpty)
            #expect(camera.received.last == (try LunaProtocol.deleteFiles(clip.uri)))
        }

        @Test func everyOtherCommandIsRefusedAndDisconnectDropsTheCamera() async throws {
            let camera = LunaReviewCamera(clips: [clip])
            let backend = LunaCameraBackend(useExistingNetwork: true)
            backend.connect(review: camera)
            await #expect(throws: LunaProtocolError.cameraRejectedRequest) {
                try await backend.send(LunaProtocol.statusRequest())
            }
            #expect(camera.received.map(\.command) == [.getOptions])
            backend.disconnect()
            #expect(!backend.isControlReady)
            await #expect(throws: (any Error).self) { try await backend.send(LunaProtocol.stopLiveRequest, timeout: .milliseconds(50)) }
            #expect(camera.received.map(\.command) == [.getOptions])
        }
    }
#endif
