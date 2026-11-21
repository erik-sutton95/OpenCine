#if canImport(VideoToolbox) && canImport(Network)
import AVFoundation
import CoreVideo
import Foundation
import OpenCineCore
import OpenCineStreaming
import OpenCineStreamingApple

/// A shared network the camera can join for its own stream (from the app's saved networks).
public struct LiveStreamNetwork: Hashable, Sendable {
    public var id: String
    public var name: String
    /// This device's own hotspot: the camera joins it and the device keeps its cellular route.
    public var isHotspot: Bool

    public init(id: String, name: String, isHotspot: Bool) {
        self.id = id
        self.name = name
        self.isHotspot = isHotspot
    }
}

/// Why the camera did not start its own stream.
public enum LiveStreamCameraError: Error, Equatable {
    /// The camera stopped answering; it may need a hard restart.
    case notResponding
    /// The camera answered with a refusal (its reply, for the log).
    case refused(String)
}

/// The app's side of "1080p from camera": a camera that can publish its own stream to this device.
/// The app implements it over its integration (the shared shell never names a manufacturer), and
/// the coordinator calls it in this order: `prepare`, `startPublishing` (after the receiver is
/// open), and on every stop or failure `endPublishing`, then `finished` once the stream is over.
@MainActor public protocol LiveStreamCameraSource: AnyObject {
    /// The selected camera's capability, or `nil` when it has none (or it is experimental and the
    /// operator has not turned experimental support on). Hides the choice when `nil`.
    var publishing: CameraStreamPublishing? { get }
    /// The saved shared networks the camera can join, this device's hotspot first.
    var networks: [LiveStreamNetwork] { get }
    /// Releases the camera from monitoring and puts this device on `network` (not needed for its
    /// own hotspot). Returns this device's address on that network.
    func prepare(_ network: LiveStreamNetwork) async throws -> String
    /// Tells the camera to join `network` and publish to `url` at `frameRate`. Throws
    /// `LiveStreamCameraError` when the camera refuses or stops answering.
    func startPublishing(to url: String, network: LiveStreamNetwork, frameRate: Int) async throws
    /// Ends the camera's stream (a bounded wait) so it returns to normal use. Never throws.
    func endPublishing() async
    /// The stream is over: the app returns to its normal connect flow for this camera.
    func finished()
}

/// What the receiver tells the coordinator, from any thread.
public enum LiveStreamCameraRelayEvent: Sendable, Equatable {
    case listenFailed
    case connected
    case firstPicture
    /// The camera's publisher went away.
    case lost
}

/// The receiver and decoders for one camera publish (`CameraStreamRelay` in production).
protocol LiveStreamCameraRelaying: AnyObject, Sendable {
    func open(
        token: StreamReceiverToken, video: @escaping @Sendable (CVPixelBuffer) -> Void,
        audio: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        events: @escaping @Sendable (LiveStreamCameraRelayEvent) -> Void)
    func close()
}

/// The production relay: the local RTMP listener with the video and audio decoders.
final class CameraStreamRelayAdapter: LiveStreamCameraRelaying, @unchecked Sendable {
    private let lock = NSLock()
    private var relay: CameraStreamRelay?

    func open(
        token: StreamReceiverToken, video: @escaping @Sendable (CVPixelBuffer) -> Void,
        audio: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        events: @escaping @Sendable (LiveStreamCameraRelayEvent) -> Void
    ) {
        let relay = CameraStreamRelay(token: token, video: video, audio: audio) { event in
            switch event {
            case .listening: break
            case .listenFailed: events(.listenFailed)
            case .connected: events(.connected)
            case .firstPicture: events(.firstPicture)
            case .lost: events(.lost)
            }
        }
        lock.withLock { self.relay = relay }
        relay.start()
    }

    func close() {
        let relay = lock.withLock { () -> CameraStreamRelay? in
            defer { self.relay = nil }
            return self.relay
        }
        relay?.stop()
    }
}

/// The relayed picture for the native monitor screen: a display layer fed by the decoder.
public final class LiveStreamCameraDisplay: @unchecked Sendable {
    public let layer = AVSampleBufferDisplayLayer()

    init() { layer.videoGravity = .resizeAspect }

    func show(_ buffer: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
            let format
        else { return }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
            let sample
        else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        // The video renderer takes samples from any thread.
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, *) {
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sample)
        }
    }
}
#endif
