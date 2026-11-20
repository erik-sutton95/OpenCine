#if canImport(VideoToolbox) && canImport(Network)
import AVFoundation
import CoreVideo
import Foundation
import OpenCineCore
import OpenCineStreaming

/// One live stream on Apple platforms: it drives the portable `StreamRun` with a TLS connection
/// (plain TCP only for a plain `rtmp://` destination),
/// the H.264 and AAC encoders and a frame clock at the output rate.
///
/// Hosts submit clean pictures of any size and PCM audio from any thread; the publisher fits each
/// picture into the fixed output frame, repeats or skips to hold the frame rate, shows a slate when
/// pictures stop for 2 seconds, and reports status through `onStatus`. It sends no camera command
/// and touches no monitor state, so a stream failure stays inside the stream.
public final class StreamPublisher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "opencine.streaming.publisher", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "opencine.streaming.audio", qos: .userInitiated)
    private let format: StreamOutputFormat
    private let makeConnection: @Sendable (String, UInt16) -> any StreamConnection
    private let now: @Sendable () -> MonotonicInstant
    private let drivesTimers: Bool

    // Touched only on `queue`.
    private var run: StreamRun
    private var connection: (any StreamConnection)?
    private var connectionGeneration = 0
    private var startedAt: MonotonicInstant?
    private var pacer = StreamFramePacer<PixelInput>()
    private var forceKeyframe = false
    private var frameTimer: DispatchSourceTimer?
    private var tickTimer: DispatchSourceTimer?
    private var statusHandler: (@Sendable (StreamRun.Status) -> Void)?
    private let video: H264StreamEncoder
    private let fitter: StreamPictureFitter

    // Touched only on `audioQueue`.
    private let audio: AACStreamEncoder?

    public convenience init(
        destination: StreamDestination, format: StreamOutputFormat, fitting: StreamPictureFitter.Mode = .fit,
        connection: (@Sendable (String, UInt16) -> any StreamConnection)? = nil,
        now: @escaping @Sendable () -> MonotonicInstant = { MonotonicInstant.now() }
    ) {
        let encrypted = destination.isEncrypted
        self.init(
            destination: destination, format: format, fitting: fitting,
            connection: connection ?? { NetworkStreamConnection(host: $0, port: $1, encrypted: encrypted) },
            now: now, drivesTimers: true)
    }

    init(
        destination: StreamDestination, format: StreamOutputFormat, fitting: StreamPictureFitter.Mode,
        connection: @escaping @Sendable (String, UInt16) -> any StreamConnection,
        now: @escaping @Sendable () -> MonotonicInstant, drivesTimers: Bool
    ) {
        self.format = format
        makeConnection = connection
        self.now = now
        self.drivesTimers = drivesTimers
        run = StreamRun(destination: destination, format: format, now: now())
        video = H264StreamEncoder(format: format)
        fitter = StreamPictureFitter(width: format.width, height: format.height, mode: fitting)
        audio = try? AACStreamEncoder(format: format)
    }

    /// Called on the publisher's queue after every change. Set it before `start()`.
    public func onStatus(_ handler: @escaping @Sendable (StreamRun.Status) -> Void) {
        queue.async { [self] in statusHandler = handler }
    }

    public var status: StreamRun.Status { queue.sync { run.status } }

    public func start() {
        queue.async { [self] in
            guard startedAt == nil else { return }
            startedAt = now()
            apply(run.start())
            if drivesTimers { startTimers() }
        }
    }

    public func stop() {
        queue.async { [self] in
            apply(run.stop(at: now()))
            frameTimer?.cancel()
            tickTimer?.cancel()
            frameTimer = nil
            tickTimer = nil
        }
    }

    /// A clean picture of any size. The newest one goes out at the next output frame.
    public func submitVideo(_ buffer: CVPixelBuffer) {
        let input = PixelInput(buffer: buffer)
        queue.async { [self] in pacer.submit(input, at: now()) }
    }

    /// PCM audio of any format; it is converted to the stream's rate and channels.
    public func submitAudio(_ buffer: AVAudioPCMBuffer) {
        let input = AudioInput(buffer: buffer)
        audioQueue.async { [self] in
            guard let audio, let start = queue.sync(execute: { startedAt }) else { return }
            let packets = audio.encode(input.buffer, startMs: Self.ms(now() - start))
            guard !packets.isEmpty else { return }
            queue.async { [self] in
                for packet in packets { apply(run.publish(packet, at: now())) }
            }
        }
    }

    // MARK: Driving (on `queue`; tests call these through `perform`)

    func perform<T>(_ body: (StreamPublisher) -> T) -> T { queue.sync { body(self) } }

    /// Encodes the output frame due at `instant`.
    func emitFrame(at instant: MonotonicInstant) {
        guard let start = startedAt, case .live = run.status.phase else { return }
        let picture: CVPixelBuffer?
        switch pacer.frame(at: instant) {
        case .picture(let input): picture = fitter.fit(input.buffer)
        case .slate: picture = fitter.slate()
        }
        guard let picture else { return }
        let force = forceKeyframe
        forceKeyframe = false
        video.encode(picture, at: Self.ms(instant - start), forceKeyframe: force) { [weak self] packets in
            guard let self else { return }
            queue.async { [self] in
                for packet in packets { apply(run.publish(packet, at: now())) }
            }
        }
    }

    func tick(at instant: MonotonicInstant) { apply(run.tick(at: instant)) }

    func handle(_ event: StreamConnectionEvent, generation: Int) {
        guard generation == connectionGeneration else { return }
        let instant = now()
        switch event {
        case .opened: apply(run.connected(at: instant))
        case .received(let bytes): apply(run.received(bytes, at: instant))
        case .wrote(let count): apply(run.wrote(count, at: instant))
        case .lost:
            connection = nil
            apply(run.connectionLost(at: instant))
        }
    }

    private func apply(_ actions: [StreamRun.Action]) {
        for action in actions {
            switch action {
            case .connect(let host, let port):
                connection?.close()
                connectionGeneration += 1
                let generation = connectionGeneration
                let opened = makeConnection(host, port)
                connection = opened
                opened.open { [weak self] event in
                    guard let self else { return }
                    queue.async { [self] in handle(event, generation: generation) }
                }
            case .write(let bytes):
                connection?.write(bytes)
            case .disconnect:
                connectionGeneration += 1
                connection?.close()
                connection = nil
            case .setVideoBitrate(let bps):
                video.setBitrate(bps)
            case .requestKeyframe:
                forceKeyframe = true
            case .wake(let due):
                guard drivesTimers else { break }
                let delay = max(.zero, due - now())
                queue.asyncAfter(deadline: .now() + Self.seconds(delay)) { [weak self] in
                    guard let self else { return }
                    tick(at: now())
                }
            }
        }
        statusHandler?(run.status)
    }

    private func startTimers() {
        let fps = max(1, format.frameRate.doubleValue)
        let frames = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        frames.schedule(deadline: .now(), repeating: 1 / fps, leeway: .milliseconds(2))
        frames.setEventHandler { [weak self] in
            guard let self else { return }
            emitFrame(at: now())
        }
        frames.resume()
        frameTimer = frames
        let ticks = DispatchSource.makeTimerSource(queue: queue)
        ticks.schedule(deadline: .now() + 1, repeating: 1)
        ticks.setEventHandler { [weak self] in
            guard let self else { return }
            tick(at: now())
        }
        ticks.resume()
        tickTimer = ticks
    }

    private static func ms(_ duration: Duration) -> UInt32 {
        let (seconds, attoseconds) = duration.components
        return UInt32(clamping: seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }

    /// Carries a read-only picture across queue hops; the source keeps ownership of its pixels.
    private struct PixelInput: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    private struct AudioInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }
}
#endif
