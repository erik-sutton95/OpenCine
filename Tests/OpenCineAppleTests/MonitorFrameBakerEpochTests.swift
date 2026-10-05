#if canImport(CoreImage) && canImport(Metal)
    import CoreImage
    import Foundation
    import Metal
    import OpenCineApple
    import Testing

    /// Real GPU bake: an externally acquired frame is current only while its baker epoch is.
    @Suite struct MonitorFrameBakerEpochTests {
        let size = CGSize(width: 8, height: 8)

        func bake(_ native: MonitorFrameBaker, red: CGFloat) throws -> MonitorFrameBaker.Frame {
            let image = CIImage(color: CIColor(red: red, green: 0, blue: 0))
                .cropped(to: CGRect(origin: .zero, size: size))
            let done = DispatchSemaphore(value: 0)
            native.scheduleBake(image: image, drawableSize: size, pixelFormat: .bgra8Unorm) {
                done.signal()
            }
            #expect(done.wait(timeout: .now() + 5) == .success, "GPU bake did not complete")
            return try #require(native.acquireFrame(for: size, pixelFormat: .bgra8Unorm))
        }

        @Test func resetRetiresAcquiredFrameAndAdmitsSuccessor() throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            let native = MonitorFrameBaker(device: device)
            defer { native.close() }
            let old = try bake(native, red: 1)
            #expect(old.isCurrent)
            native.reset()
            #expect(!old.isCurrent, "reset must retire an externally acquired frame")
            #expect(native.acquireFrame(for: size, pixelFormat: .bgra8Unorm) == nil)
            let successor = try bake(native, red: 0.5)
            #expect(successor.isCurrent)
            #expect(!old.isCurrent, "a successor publication cannot revive a retired frame")
            #expect(successor.texture !== old.texture, "a held acquisition keeps its texture")
            native.releaseBakedTexture(old.texture)
            native.releaseBakedTexture(successor.texture)
        }

        @Test func closeRetiresAcquiredFrameTerminally() throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            let native = MonitorFrameBaker(device: device)
            let held = try bake(native, red: 1)
            #expect(held.isCurrent)
            native.close()
            #expect(!held.isCurrent, "close must retire an externally acquired frame")
            #expect(native.acquireFrame(for: size, pixelFormat: .bgra8Unorm) == nil)
            native.releaseBakedTexture(held.texture)
        }
    }
#endif
