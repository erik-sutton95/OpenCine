#if canImport(Vision)
    import CoreVideo
    import Testing

    @testable import OpenCineCameraControls

    @Suite struct LiveFaceDetectorTests {
        /// Feed rate while a face is held; 10 Hz after about a second of empty frames.
        @Test func paceDropsToIdleAfterEmptyRuns() {
            #expect(LiveFaceDetector.pace(emptyRuns: 0) == LiveFaceDetector.interval)
            #expect(
                LiveFaceDetector.pace(emptyRuns: LiveFaceDetector.idleAfterEmptyRuns - 1) == 0.04)
            #expect(LiveFaceDetector.pace(emptyRuns: LiveFaceDetector.idleAfterEmptyRuns) == 0.1)
        }

        @Test func blankFrameHasNoFaces() throws {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            let frame = try #require(buffer)
            #expect(LiveFaceDetector.detect(in: frame).faces.isEmpty)
            #expect(LiveFaceDetector.detect(in: frame, rectanglesOnly: true).faces.isEmpty)
        }
    }
#endif
