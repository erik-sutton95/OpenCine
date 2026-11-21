import Foundation
import OpenCineCore
import OpenCineDJI

/// The Bluetooth link a livestream is provisioned over (`DjiAppleMultiviewProvisioner` on iOS).
@MainActor public protocol DJILivestreamLink: AnyObject {
    func next() -> UInt16
    func exchange(_ frame: Duml.Frame, timeout: TimeInterval) async throws -> Duml.Frame
    /// Closes the link and returns once it is down.
    func closeAndWait() async
}

/// Why a camera did not start its own livestream. Replies are kept for the log; none carries a
/// secret.
public enum DJICameraStreamError: Error, Equatable, Sendable {
    /// A required command got no reply: the camera may need a hard restart.
    case noReply
    case prepareRefused([UInt8])
    case joinRefused([UInt8])
    case configureRefused([UInt8])
    case startRefused([UInt8])
    case addressTooLong
}

/// Starts and ends a DJI camera's own RTMP livestream to this device, in the order proven on a
/// Pocket 4 Pro (2026-11-21, after Moblin's captures): end any earlier livestream, livestream mode
/// (`02/E1 1A`), a 1 s settle, join the shared network (`07/47`, retried per
/// `MulticamJoinPolicy`), configure the address (`08/78`: version 00 on Pocket 3, the JSON form
/// otherwise) and start (`02/8E`). The log holds no password and only the stream key's first 4
/// characters.
@MainActor public final class DJICameraStreamPublisher {
    /// About 6 Mbps: the camera's own 1080p encode.
    public static let bitrateKbps: UInt16 = 6000

    private let link: any DJILivestreamLink
    private let model: CameraModel
    private let log: (String) -> Void
    private let sleep: (Duration) async throws -> Void

    public init(
        link: any DJILivestreamLink, model: CameraModel, log: @escaping (String) -> Void = { _ in },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.link = link
        self.model = model
        self.log = log
        self.sleep = sleep
    }

    /// Asks the camera to join `ssid` and publish to `url`. Throws `DJICameraStreamError` (or
    /// `CancellationError`); the caller ends the stream with `end()` either way.
    public func start(url: String, ssid: String, password: String, frameRate: Int, codec: LivestreamCommands.Codec)
        async throws
    {
        log("livestream: start \(Self.redacted(url)) on \(ssid), \(frameRate) fps, \(model.isPocket3 ? "AVC" : codec.rawValue)")
        // A livestream left over from an earlier session; no reply is needed.
        _ = try? await exchange("end (cleanup)", LivestreamCommands.end(seq: link.next()), timeout: 5)
        try Task.checkCancellation()

        let prepared = try await required("livestream mode", LivestreamCommands.prepare(seq: link.next()), timeout: 12)
        guard prepared.first == 0 else { throw DJICameraStreamError.prepareRefused(prepared) }
        try await sleep(.seconds(1))

        try await join(ssid: ssid, password: password)

        let preset = LivestreamCommands.preset(frameRate: frameRate, bitrateKbps: Self.bitrateKbps)
        let configure: Duml.Frame
        do {
            configure = model.isPocket3
                ? try LivestreamCommands.configureDirectURL(url: url, preset: preset, seq: link.next())
                : try LivestreamCommands.configureJSON(url: url, preset: preset, codec: codec, seq: link.next())
        } catch {
            throw DJICameraStreamError.addressTooLong
        }
        let configured = try await required("configure", configure, timeout: 12)
        guard configured.first == 0 else { throw DJICameraStreamError.configureRefused(configured) }

        let started = try await required("start", LivestreamCommands.start(seq: link.next()), timeout: 12)
        guard started.first == 0 else { throw DJICameraStreamError.startRefused(started) }
    }

    /// Ends the camera's livestream (6 s at most; the reply is not needed) and closes the link.
    public func end() async {
        _ = try? await exchange("end", LivestreamCommands.end(seq: link.next()), timeout: 6)
        await link.closeAndWait()
        log("livestream: link closed")
    }

    private func join(ssid: String, password: String) async throws {
        var lastReply: [UInt8]?
        for attempt in 1...MulticamJoinPolicy.maximumAttempts {
            let frame = try MulticamCommands.join(ssid: ssid, password: password, seq: link.next())
            // The request carries the password; only the reply is logged.
            guard let reply = try? await exchange("join attempt \(attempt)", frame,
                timeout: MulticamJoinPolicy.replyTimeoutSeconds)
            else {
                try Task.checkCancellation()
                continue
            }
            lastReply = reply
            switch MulticamJoinPolicy.decision(reply: reply, attempt: attempt) {
            case .connected: return
            case .retry: try await sleep(.seconds(MulticamJoinPolicy.retryDelaySeconds))
            case .rejected: throw DJICameraStreamError.joinRefused(reply)
            }
        }
        throw lastReply.map(DJICameraStreamError.joinRefused) ?? DJICameraStreamError.noReply
    }

    private func required(_ label: String, _ frame: Duml.Frame, timeout: TimeInterval) async throws -> [UInt8] {
        do {
            return try await exchange(label, frame, timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DJICameraStreamError.noReply
        }
    }

    private func exchange(_ label: String, _ frame: Duml.Frame, timeout: TimeInterval) async throws -> [UInt8] {
        do {
            let reply = try await link.exchange(frame, timeout: timeout)
            log("livestream: \(label) reply \(Duml.hex(reply.payload))")
            return reply.payload
        } catch {
            log("livestream: \(label) no reply")
            throw error
        }
    }

    /// The address with its stream key cut to the first 4 characters.
    static func redacted(_ url: String) -> String {
        guard let slash = url.lastIndex(of: "/") else { return url }
        let key = url[url.index(after: slash)...]
        return url[...slash] + key.prefix(4) + "****"
    }
}

#if os(iOS)
extension DjiAppleMultiviewProvisioner: DJILivestreamLink {}

extension DJICameraStreamPublisher {
    /// Connects and pairs over Bluetooth with `camera`, ready to `start`.
    public static func connect(
        camera: DjiAppleSighting, host: DjiAppleTransportHost, log: @escaping (String) -> Void = { _ in }
    ) async throws -> DJICameraStreamPublisher {
        let link = DjiAppleMultiviewProvisioner(host: host)
        do {
            try await link.connect(camera, pairingTimeout: 30)
        } catch {
            await link.closeAndWait()
            throw error
        }
        return DJICameraStreamPublisher(link: link, model: camera.model, log: log)
    }
}
#endif
