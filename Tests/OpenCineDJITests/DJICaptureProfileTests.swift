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

    /// Behavior audit PAA-200..203 / PIA-202/203/240: every Osmo body answered the Auto ISO
    /// ceiling GET/SET and hopped to the new curve's native ISO in the standalone apps, so the
    /// DJI profile declares both services. A drone declares nothing (unknown).
    @Test func osmoBodiesDeclareNativeISOServices() {
        let bodies: [(Int, String)] = [
            (0x0020, "Osmo Pocket 3"), (0x0021, "Osmo Pocket 4"), (0x0022, "Osmo Pocket 4 Pro"),
            (0x0019, "Osmo Nano"), (0x0018, "Osmo Action 6"),
        ]
        for (id, name) in bodies {
            let profile = DJICaptureCapabilityProfile.make(for: CameraModel.resolve(modelId: id, name: name))
            #expect(profile.nativeISO == CaptureNativeISOCapabilities(hop: true, ceiling: true), "\(name)")
        }
        let drone = CameraModel(name: "DJI Neo", isDrone: true)
        #expect(DJICaptureCapabilityProfile.make(for: drone).nativeISO == CaptureNativeISOCapabilities())
    }

}
