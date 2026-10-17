#if canImport(CoreImage)
import CoreImage
import Foundation
import OpenCineMedia
import Testing

@testable import OpenCineApple

/// One definition of the zebra zones every app paints, for any source curve and ceiling.
@Suite struct MonitorZebraZoneTests {
    @Test func theZonesFollowTheSharedScaleAndClipShelf() {
        let spec = MonitorZebraSpec(highlightIRE: 100, midtoneIRE: 55)
        let zones = MonitorCodeZebraSpec(spec, transfer: .log3G10, clipByte: 180)
        #expect(zones.thresholds.highlight == Double(180 - ScopeAnchors.clipShelfCodes) / 255)
        let half = LiveZebra.midtoneHalfWidthIRE
        let lower = ScopeDisplayScale.signalNative(
            monitorPercent: 55 - half, transfer: .log3G10, clipByte: 180)
        let upper = ScopeDisplayScale.signalNative(
            monitorPercent: 55 + half, transfer: .log3G10, clipByte: 180)
        #expect(abs((zones.thresholds.midtoneLower ?? 0) - lower) < 1e-12)
        #expect(abs((zones.thresholds.midtoneUpper ?? 0) - upper) < 1e-12)
        #expect(zones.maskPolicy == MonitorZebraMaskPolicy(highlightMeasure: .maximumComponent))
        let off = MonitorCodeZebraSpec(
            MonitorZebraSpec(highlightEnabled: false, midtoneEnabled: false),
            transfer: .dlog2, clipByte: 247)
        let none = MonitorZebraCodeThresholds(
            highlight: nil, midtoneLower: nil, midtoneUpper: nil)
        #expect(off.thresholds == none)
    }

    @Test func aClippedChannelUnderLowLumaIsStriped() {
        let extent = CGRect(x: 0, y: 0, width: 16, height: 16)
        // Saturated blue: blue 200 is over the 173 shelf, luma is about 66.
        let source = CIImage(color: CIColor(red: 40 / 255, green: 60 / 255, blue: 200 / 255))
            .cropped(to: extent)
        let painted = MonitorImageCompositor.applyZebra(
            over: source, source: source, extent: extent,
            zebra: MonitorZebraSpec(highlightIRE: 100, midtoneEnabled: false),
            transfer: .log3G10, clipByte: 180)
        let context = CIContext(options: [
            .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        ])
        func pixels(_ image: CIImage) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: 16 * 16 * 4)
            context.render(
                image, toBitmap: &out, rowBytes: 64, bounds: extent, format: .RGBA8,
                colorSpace: nil)
            return out
        }
        #expect(pixels(painted) != pixels(source))
    }
}
#endif
