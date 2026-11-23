import Foundation

/// A camera that can encode and publish its own stream to an RTMP address on a shared network,
/// declared by its integration. The phone receives that stream and relays it, so the picture is
/// the camera's own encoding: sharper than a live view, but without the phone's LUT when
/// `takesLUT` is false. Kotlin twin: `CameraStreamPublishing` in `core`.
public struct CameraStreamPublishing: Hashable, Sendable {
    public enum Codec: String, Hashable, Sendable {
        case h264
        case hevc
    }

    /// The picture size the camera publishes.
    public var width: Int
    public var height: Int
    /// The frame rates the camera can publish at, in no particular order.
    public var frameRates: [Int]
    /// The codecs the camera can publish, preferred first.
    public var codecs: [Codec]
    /// Whether the published picture is in a curve a monitor LUT is made for.
    public var takesLUT: Bool
    /// Not yet confirmed on hardware: offered only behind the operator's experimental switch.
    public var experimental: Bool

    public init(
        width: Int, height: Int, frameRates: [Int], codecs: [Codec], takesLUT: Bool, experimental: Bool
    ) {
        self.width = width
        self.height = height
        self.frameRates = frameRates
        self.codecs = codecs
        self.takesLUT = takesLUT
        self.experimental = experimental
    }

    /// The codec the camera is asked for.
    public var preferredCodec: Codec? { codecs.first }

    /// The requested rate when the camera lists it; otherwise the highest listed rate at or below
    /// 30, otherwise the lowest listed rate (30 when none is listed).
    public func frameRate(near requested: Int?) -> Int {
        if let requested, frameRates.contains(requested) { return requested }
        return frameRates.filter { $0 <= 30 }.max() ?? frameRates.min() ?? 30
    }
}
