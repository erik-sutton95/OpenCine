#if canImport(Network) && canImport(VideoToolbox)
import AVFoundation
import CoreVideo
import Foundation
import OpenCineStreaming

/// One camera's own publish into this device: the local RTMP listener, the video decoder and the
/// AAC decoder, reduced to what the live stream needs. Pictures and sound arrive on the
/// receiver's queue or VideoToolbox's thread; events arrive on the receiver's queue.
public final class CameraStreamRelay: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case listening
        /// The port could not be opened (another app holds it, or the network refused).
        case listenFailed
        /// The camera began publishing under the expected key.
        case connected
        /// The first decoded picture of this publish.
        case firstPicture
        /// The camera's publish ended or its connection dropped.
        case lost
    }

    private let receiver: RTMPLocalReceiver
    private let video: RTMPVideoDecoder
    private let audio: RTMPAudioDecoder
    // Touched on the receiver's queue, except `pictureSeen` (under `lock`, VideoToolbox's thread).
    private let lock = NSLock()
    private var publishing = false
    private var pictureSeen = false

    public init(
        port: UInt16 = 1935, token: StreamReceiverToken, video: @escaping @Sendable (CVPixelBuffer) -> Void,
        audio: @escaping @Sendable (AVAudioPCMBuffer) -> Void, events: @escaping @Sendable (Event) -> Void
    ) {
        final class Owner: @unchecked Sendable { weak var relay: CameraStreamRelay? }
        let owner = Owner()
        self.video = RTMPVideoDecoder(
            onPicture: { picture in
                guard let relay = owner.relay else { return }
                let first = relay.lock.withLock { () -> Bool in
                    defer { relay.pictureSeen = true }
                    return relay.publishing && !relay.pictureSeen
                }
                if first { events(.firstPicture) }
                video(picture.pixelBuffer)
            }, onError: { _ in })
        self.audio = RTMPAudioDecoder(onBuffer: audio)
        self.receiver = RTMPLocalReceiver(port: port, token: token) { event in
            owner.relay?.handle(event, events: events)
        }
        owner.relay = self
    }

    public func start() { receiver.start() }

    public func stop() {
        receiver.stop()
        receiver.queue.async { [video] in video.invalidate() }
    }

    private func handle(_ event: RTMPLocalReceiver.Event, events: @Sendable (Event) -> Void) {
        switch event {
        case .listening: events(.listening)
        case .listenFailed: events(.listenFailed)
        case .publisherConnected: break
        case .publisherDisconnected:
            let was = lock.withLock { () -> Bool in
                defer {
                    publishing = false
                    pictureSeen = false
                }
                return publishing
            }
            video.reset()
            if was { events(.lost) }
        case .session(let session):
            switch session {
            case .publish:
                lock.withLock {
                    publishing = true
                    pictureSeen = false
                }
                events(.connected)
            case .videoConfig(let codec, let record, _): video.configure(codec: codec, record: record)
            case .videoFrame(let frame): video.decode(frame)
            case .audioConfig(let config): audio.configure(audioSpecificConfig: config)
            case .audioFrame(_, let bytes): audio.decode(bytes)
            default: break
            }
        }
    }
}
#endif
