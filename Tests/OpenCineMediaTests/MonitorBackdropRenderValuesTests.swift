import OpenCineMedia
import Testing

@Suite struct MonitorBackdropRenderValuesTests {
    @Test func boundsKeepOriginalCeilScaleAndCadence() throws {
        let scaled = try #require(MonitorBackdropRenderValues.rasterSize(width: 900, height: 600))
        #expect(scaled.width == 320 && scaled.height == 214)
        #expect(scaled.scale == 320.0 / 900.0)
        let small = try #require(MonitorBackdropRenderValues.rasterSize(width: 8, height: 8))
        #expect(small.width == 8 && small.height == 8 && small.scale == 1)
        #expect(MonitorBackdropRenderValues.minimumInterval == 1.0 / 60.0)
        #expect(MonitorBackdropRenderValues.minimumIntervalNanoseconds == 16_666_667)
    }
    @Test func invalidCanvasCannotInventARaster() {
        for invalid in [Double.nan, .infinity, -.infinity, -1, 0, 1] {
            #expect(MonitorBackdropRenderValues.rasterSize(width: invalid, height: 20) == nil)
            #expect(MonitorBackdropRenderValues.rasterSize(width: 20, height: invalid) == nil)
        }
    }
    @Test func sharedProductsKeepFirstOccurrenceOrder() {
        let compact = MonitorBackdropBlurProduct(radius: 18, saturation: 1.25)
        let expanded = MonitorBackdropBlurProduct(radius: 20, saturation: 1.25)
        let zoom = MonitorBackdropBlurProduct(radius: 24, saturation: 1.25)
        let scope = MonitorBackdropBlurProduct(radius: 8, saturation: 1)
        #expect(MonitorBackdropRenderValues.distinctProducts([compact, expanded, expanded,
            expanded, zoom, scope, compact]) == [compact, expanded, zoom, scope])
    }
    @Test func unknownMapReadinessDiffersFromKnownClip() {
        #expect(MonitorBackdropLookState(clipByte: 220, mapClipByte: nil)
            != MonitorBackdropLookState(clipByte: 220, mapClipByte: 0))
        #expect(MonitorBackdropLookState(clipByte: 220, mapClipByte: nil)
            != MonitorBackdropLookState(clipByte: 220, mapClipByte: 220))
    }
}
