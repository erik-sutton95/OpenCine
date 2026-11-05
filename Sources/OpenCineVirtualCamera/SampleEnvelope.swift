#if canImport(CoreMedia)
import CoreMedia

/// Changes output cadence without copying picture storage or losing sample metadata.
public enum SampleEnvelope {
    public enum Failure: Error { case coreMedia(OSStatus) }

    public static func retime(
        _ sample: CMSampleBuffer, outputTime: CMTime, duration: CMTime
    ) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: duration, presentationTimeStamp: outputTime, decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleBufferOut: &output)
        guard status == noErr, let output else { throw Failure.coreMedia(status) }
        return output
    }
}
#endif
