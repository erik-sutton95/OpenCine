#if os(iOS)
import AVFoundation
import Foundation

public enum StreamMicrophoneError: Error, Equatable, Sendable {
    /// The user has not allowed microphone access. The usage text is the app's
    /// `NSMicrophoneUsageDescription`.
    case permissionDenied
}

/// The device microphone (or a connected headset or capture card that offers audio) for the stream,
/// as PCM buffers in the input's own format; the AAC encoder converts them to 48 kHz stereo.
/// One source stays on through every cut.
public final class StreamMicrophone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var running = false

    public init() {}

    /// Asks for microphone access once; later calls return the saved answer.
    public static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    public func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard !running else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw StreamMicrophoneError.permissionDenied
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true)
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1_024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            onBuffer(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    public func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
