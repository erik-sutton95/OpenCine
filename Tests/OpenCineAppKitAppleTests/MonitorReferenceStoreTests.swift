#if os(iOS)
    import CoreGraphics
    import Foundation
    import OpenCineAppKitApple
    import Testing

    struct MonitorReferenceStoreTests {
        @MainActor @Test func rotatedReferenceSurvivesRestartAndFailedReplacement() async throws {
            let directory = FileManager.default.temporaryDirectory.appending(
                path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let context = try #require(
                CGContext(
                    data: nil, width: 16, height: 9, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
            let image = try #require(context.makeImage())
            let store = MonitorReferenceStore(directory: directory)
            await store.save { .init(image: image, displayAspect: 9.0 / 16, orientation: .right) }
            let saved = try #require(store.saved)
            #expect(saved.image.width == 9)
            #expect(saved.image.height == 16)
            store.visible = true

            await store.save { nil }
            #expect(store.saved?.displayAspect == 9.0 / 16)
            #expect(store.notice != nil)

            let reopened = MonitorReferenceStore(directory: directory)
            #expect(reopened.saved?.image.height == 16)
            #expect(reopened.saved?.displayAspect == 9.0 / 16)
            #expect(!reopened.visible)
            #expect(reopened.blend == 0.5)
            #expect(reopened.divider == 0.5)
        }
    }
#endif
