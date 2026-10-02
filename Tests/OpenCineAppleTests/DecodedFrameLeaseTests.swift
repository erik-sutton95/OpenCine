#if canImport(CoreVideo)
    import CoreVideo
    import OpenCineApple
    import OpenCineCore
    import Testing

    func makeBuffer(width: Int = 16, height: Int = 16) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        precondition(status == kCVReturnSuccess)
        return buffer!
    }

    /// MEDIA-02 gate (tests only): no stale-generation publication and no lease that outlives
    /// its release.
    @Suite struct DecodedFrameLeaseTests {
        @Test func leaseCarriesIdentityAndFormat() {
            let fence = DecodedFrameFence()
            let lease = fence.lease(makeBuffer(width: 32, height: 18), timeNs: 7)
            #expect(lease.stream == fence.stream)
            #expect(lease.generation == fence.generation)
            #expect(
                lease.format
                    == DecodedFrameFormat(
                        width: 32, height: 18, pixelFormat: kCVPixelFormatType_32BGRA))
            #expect(lease.timeNs == 7)
        }

        @Test func releaseDropsTheSurfaceExactlyOnce() {
            let buffer = makeBuffer()
            let held = CFGetRetainCount(buffer)
            let lease = DecodedFrameLease(buffer, stream: StreamID(), generation: StreamGeneration())
            #expect(CFGetRetainCount(buffer) == held + 1)
            #expect(lease.pixelBuffer === buffer)
            lease.release()
            #expect(lease.isReleased)
            #expect(lease.pixelBuffer == nil)
            #expect(CFGetRetainCount(buffer) == held, "a released lease keeps no reference")
            lease.release()
            #expect(CFGetRetainCount(buffer) == held)
        }

        @Test func advanceMakesEveryEarlierGenerationStale() {
            let fence = DecodedFrameFence()
            let first = fence.generation
            let second = fence.advance()
            #expect(second > first)
            #expect(!fence.isCurrent(first))
            #expect(fence.isCurrent(second))
        }

        @Test func publishLendsOnlyCurrentLeases() {
            let fence = DecodedFrameFence()
            let stale = fence.lease(makeBuffer())
            fence.advance()
            var lent: [DecodedFrameLease] = []
            #expect(!fence.publish(stale) { lent.append($0) })
            #expect(stale.isReleased, "a refused lease is released, not left holding a surface")

            let foreign = DecodedFrameFence().lease(makeBuffer())
            #expect(!fence.publish(foreign) { lent.append($0) })
            #expect(foreign.isReleased)

            let released = fence.lease(makeBuffer())
            released.release()
            #expect(!fence.publish(released) { lent.append($0) })

            let current = fence.lease(makeBuffer())
            #expect(fence.publish(current) { lent.append($0) })
            #expect(lent.count == 1 && lent[0] === current)
            #expect(!current.isReleased, "publishing lends; the owner decides when to release")
        }

        @Test func explicitGenerationIsKept() {
            let fence = DecodedFrameFence()
            let old = fence.generation
            fence.advance()
            let lease = fence.lease(makeBuffer(), generation: old)
            #expect(lease.generation == old)
            #expect(!fence.publish(lease) { _ in Issue.record("stale lease published") })
        }
    }
#endif
