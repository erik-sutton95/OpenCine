#if os(iOS)
import AVFAudio
import CoreMedia
import Speech
import Testing

@testable import OpenCineAppKitApple

@Suite struct MonitorVoiceMicrophoneInputTests {
    @Test func convertedAudioLetsTheAnalyzerAdvanceTheTimeline() async throws {
        guard #available(iOS 26, *) else { return }
        let native = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let speech = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = try #require(AVAudioConverter(from: native, to: speech))
        let (inputs, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let microphone = MonitorVoiceMicrophoneInput(converter: converter, output: speech, continuation: continuation) {
            Issue.record("Converting a stable microphone input interrupted the stream.")
        }
        // 1,024 microphone frames do not map to a whole number of 16 kHz frames.
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: native, frameCapacity: 1_024))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?.pointee)
        samples.initialize(repeating: 0, count: Int(buffer.frameLength))
        for _ in 0..<4 { microphone.append(buffer) }
        continuation.finish()

        var submitted = 0
        for await input in inputs {
            #expect(input.bufferStartTime == nil)
            #expect(input.buffer.frameLength > 0)
            submitted += 1
        }
        #expect(submitted >= 2)
    }
}
#endif
