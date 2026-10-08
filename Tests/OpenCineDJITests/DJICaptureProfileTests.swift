import Foundation
import Testing
@testable import OpenCineDJI

@Suite struct DJICaptureProfileTests {
    @Test func familyCatalogueDoesNotClaimOtherIntegrationsColorModes() {
        // No body family offers them; only a camera that reports them lists them.
        for family in [CameraBodyFamily.pocket, .nano, .other] {
            #expect(!ColorMode.available(for: family).contains(.iLog))
            #expect(!ColorMode.available(for: family).contains(.dolbyVision))
        }
    }

    @Test func largerSizesHaveNoDJIByteAndLabelBySize() {
        let sizes: [(VideoResolution, String, VideoAspect?)] = [
            (.p8K, "8K", .sixteenNine), (.p6K, "6K", .sixteenNine), (.p3K, "3K", .sixteenNine),
            (.p4K_9x16, "4K 9:16", .nineSixteen), (.p8K_235, "8K 2.35:1", nil), (.p4K_235, "4K 2.35:1", nil),
        ]
        for (size, label, aspect) in sizes {
            #expect(size.rawValue >= 0xD0, "outside every DJI resolution byte")
            #expect(size.label == label)
            #expect(size.aspect == aspect)
            #expect(size.pocket3ZoomMax == nil)
        }
    }

}
