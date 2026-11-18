import Foundation
import OpenCineCore

/// What a camera feed really delivers. `frameRate` is `nil` when the source does not state it.
public struct StreamSourceFormat: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Rational?

    public init(width: Int, height: Int, frameRate: Rational?) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
    }
}

/// The fixed encoder settings of one stream. They stay the same from go-live to stop, through
/// every cut; each source is scaled into this frame keeping its own shape.
public struct StreamOutputFormat: Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Rational
    public var videoBitrateBps: Int
    public var keyframeIntervalSeconds: Int
    public var audioBitrateBps: Int
    public var audioSampleRate: Int
    public var audioChannels: Int

    public init(
        width: Int, height: Int, frameRate: Rational, videoBitrateBps: Int, keyframeIntervalSeconds: Int,
        audioBitrateBps: Int, audioSampleRate: Int, audioChannels: Int
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoBitrateBps = videoBitrateBps
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
        self.audioBitrateBps = audioBitrateBps
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
    }
}

public extension StreamOutputFormat {
    /// The output for a stream, set at go-live. The stream matches the source and never pretends
    /// to more: the best connected source sets the size (1080p only from a real 1080p source),
    /// the selected camera sets the frame rate, and the preset caps the bitrate and sets the shape.
    static func resolve(
        selected: StreamSourceFormat, connected: [StreamSourceFormat], preset: StreamServicePreset
    ) -> StreamOutputFormat {
        let bestHeight = ([selected] + connected).map(\.height).max() ?? selected.height
        var width: Int
        var height: Int
        var bitrate: Int
        if bestHeight >= 1080 {
            (width, height, bitrate) = (1920, 1080, 6_000_000)
        } else if bestHeight >= 720 {
            (width, height, bitrate) = (1280, 720, 3_000_000)
        } else {
            height = max(2, bestHeight / 2 * 2)
            width = Int((Double(height) * 16 / 9 / 2).rounded()) * 2
            bitrate = 2_000_000
        }
        if let cap = preset.maxVideoBitrateBps { bitrate = min(bitrate, cap) }
        if preset.aspect == .portrait9x16 { swap(&width, &height) }
        return StreamOutputFormat(
            width: width, height: height, frameRate: selected.frameRate ?? Rational(30, 1),
            videoBitrateBps: bitrate, keyframeIntervalSeconds: 2, audioBitrateBps: 160_000,
            audioSampleRate: 48_000, audioChannels: 2)
    }
}

/// How the phone or computer reaches the camera, as the host app states it. Decides whether
/// streaming is possible: it needs a route to the internet besides the camera link.
public enum StreamConnectionRoute: Hashable, Sendable {
    /// A USB-C cable to the camera; the device's own network stays free.
    case usbCable
    /// HDMI through a UVC capture card.
    case captureCard
    /// The camera and the device share a Wi-Fi network that reaches the internet.
    case sharedWiFi
    /// The camera joins the device's own hotspot; the device keeps its cellular route.
    case deviceHotspot
    /// The device joins the camera's own Wi-Fi network, assumed to have no internet.
    case cameraWiFi
}

public extension StreamConnectionRoute {
    /// Whether a stream may start on this route. An unknown route (`nil`) may not.
    static func canStream(_ route: StreamConnectionRoute?) -> Bool {
        switch route {
        case .usbCable, .captureCard, .sharedWiFi, .deviceHotspot: true
        case .cameraWiFi, nil: false
        }
    }
}
