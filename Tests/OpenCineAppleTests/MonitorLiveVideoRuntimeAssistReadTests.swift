#if canImport(UIKit) && canImport(VideoToolbox)
    import OpenCineApple
    import OpenCineMedia
    import Testing

    /// The assist settings provider is an observation-tracked read on the main actor, and the
    /// runtime calls it for every access unit (30 to 60 Hz). An unchanged transfer must not
    /// read it a second time.
    @MainActor @Suite struct MonitorLiveVideoRuntimeAssistReadTests {
        @Test func eachAccessUnitReadsTheAssistSettingsOnceUntilTheTransferChanges() {
            let runtime = MonitorLiveVideoRuntime()
            defer { runtime.close() }
            let source = runtime.sourceToken
            var demandReads = 0
            var transfer = MonitorTransfer.rec709
            runtime.demandProvider = {
                demandReads += 1
                return MonitorVideoDemand()
            }
            runtime.transferProvider = { transfer }
            runtime.incomingTransfer = .rec709
            demandReads = 0
            // SIMULATED trailing picture with no parameter sets: nothing decodes.
            let accessUnit: [UInt8] = [0, 0, 0, 1, 0x02, 0x01, 0xD0]
            for _ in 0..<3 { runtime.decode(accessUnit: accessUnit, source: source) }
            #expect(demandReads == 3)
            transfer = .hdr
            runtime.decode(accessUnit: accessUnit, source: source)
            #expect(demandReads == 5, "A changed transfer pushes the policy with fresh settings")
            #expect(runtime.incomingTransfer == .hdr)
        }
    }
#endif
