import CoreMedia
import CoreVideo
import Testing

@testable import OpenCineVirtualCamera

@Test func retimingPreservesOriginalPictureAndFrameIdentity() throws {
    var image: CVPixelBuffer?
    #expect(
        CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &image)
            == kCVReturnSuccess)
    let pixels = try #require(image)
    var description: CMVideoFormatDescription?
    #expect(
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &description)
            == noErr)
    let format = try #require(description)
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(value: 1, timescale: 1), decodeTimeStamp: .invalid)
    var input: CMSampleBuffer?
    #expect(
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &input) == noErr)
    let sample = try #require(input)
    let key = "OpenZCine.FrameIdentity" as CFString
    CMSetAttachment(
        sample, key: key, value: "frame-7" as CFString,
        attachmentMode: kCMAttachmentMode_ShouldPropagate)
    let output = try SampleEnvelope.retime(
        sample, outputTime: CMTime(value: 2, timescale: 1),
        duration: CMTime(value: 1, timescale: 60))
    #expect(CMSampleBufferGetPresentationTimeStamp(output) == CMTime(value: 2, timescale: 1))
    #expect(CMSampleBufferGetDuration(output) == CMTime(value: 1, timescale: 60))
    #expect(CMSampleBufferGetPresentationTimeStamp(sample) == CMTime(value: 1, timescale: 1))
    #expect(CMSampleBufferGetImageBuffer(output) === pixels)
    #expect(CMGetAttachment(output, key: key, attachmentModeOut: nil) as? String == "frame-7")
}
