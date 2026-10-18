#if os(iOS) && canImport(MetalKit) && canImport(MetalPerformanceShaders)
    import Metal
    import MetalKit
    import OpenCineApple
    import QuartzCore
    import Testing

    /// A2-31: the shared presenter puts its view in the drawable the options ask for, a float
    /// extended-range drawable while HDR display is on, so every app's Metal feed honors the
    /// one HDR display owner. Bakes stay 8-bit display-referred.
    @MainActor @Suite struct MonitorMetalPicturePresenterHDRTests {
        @Test func hdrOptionsSwitchTheViewToTheExtendedRangeDrawableAndBack() throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            let baker = MonitorFrameBaker(device: device)
            defer { baker.close() }
            nonisolated(unsafe) var hdr = true
            let presenter = MonitorMetalPicturePresenter(device: device, baker: baker,
                options: { MonitorPresentationOptions(hdr: hdr, hdrGain: 2) })
            defer { presenter.close() }
            let view = MTKView(frame: CGRect(x: 0, y: 0, width: 8, height: 8), device: device)
            presenter.attach(view)
            presenter.configureDisplay(view)
            let layer = try #require(view.layer as? CAMetalLayer)
            #expect(view.colorPixelFormat == .rgba16Float)
            #expect(layer.wantsExtendedDynamicRangeContent)
            #expect(MonitorPresentationOptions.bakePixelFormat == .bgra8Unorm)
            hdr = false
            presenter.configureDisplay(view)
            #expect(view.colorPixelFormat == .bgra8Unorm)
            #expect(!layer.wantsExtendedDynamicRangeContent)
        }
    }
#endif
