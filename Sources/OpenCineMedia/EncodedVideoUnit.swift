import Foundation
import OpenCineCore

/// One compressed picture unit as an integration hands it to a decoder runtime (plan 6.1).
///
/// Vendor framing is already removed. A plain value with no platform objects: sample buffers,
/// codec input buffers and surfaces belong to the native decoder that consumes it. A decoder
/// drops units whose `generation` is older than the stream's current one.
public struct EncodedVideoUnit: Equatable, Sendable {
    public enum Codec: Equatable, Sendable {
        case hevc
        case avc
        /// One complete JPEG image per unit (network live view).
        case jpeg

        public init(_ codec: LiveVideoCodec) {
            switch codec {
            case .hevc: self = .hevc
            case .avc: self = .avc
            }
        }
    }

    /// Clockwise rotation that makes the coded raster upright.
    public enum Rotation: Int, Equatable, Sendable {
        case none = 0
        case clockwise90 = 90
        case upsideDown = 180
        case clockwise270 = 270
    }

    public struct Format: Equatable, Sendable {
        /// Coded raster size in pixels.
        public var width: Int
        public var height: Int
        public var rotation: Rotation
        /// Mirrored horizontally after rotation.
        public var mirrored: Bool

        public init(width: Int, height: Int, rotation: Rotation = .none, mirrored: Bool = false) {
            self.width = width
            self.height = height
            self.rotation = rotation
            self.mirrored = mirrored
        }

        /// Size of the picture once it is upright.
        public var uprightSize: (width: Int, height: Int) {
            switch rotation {
            case .none, .upsideDown: (width, height)
            case .clockwise90, .clockwise270: (height, width)
            }
        }
    }

    public let stream: StreamID
    public let generation: StreamGeneration
    public let codec: Codec
    /// H.26x: one Annex-B access unit, start codes kept. JPEG: one complete image.
    public let payload: [UInt8]
    /// A decoder can start here: H.26x parameter sets or an IRAP/IDR picture; every JPEG.
    public let isRandomAccess: Bool
    /// The parameter sets this unit decodes against (HEVC VPS/SPS/PPS, AVC SPS/PPS), start codes
    /// removed, in stream order. Equal sets mean the same decoder configuration. Empty for JPEG.
    public let parameterSets: [[UInt8]]
    /// Seconds on the host monotonic clock when the unit was complete
    /// (`ProcessInfo.systemUptime`, `CACurrentMediaTime`, `SystemClock.elapsedRealtimeNanos / 1e9`).
    public let hostArrival: TimeInterval
    /// Source presentation time in seconds, or nil when the transport carries none.
    public let presentationTime: TimeInterval?
    /// Nil until the integration or the decoder knows it.
    public let format: Format?

    public init(
        stream: StreamID, generation: StreamGeneration, codec: Codec, payload: [UInt8],
        isRandomAccess: Bool, parameterSets: [[UInt8]], hostArrival: TimeInterval,
        presentationTime: TimeInterval? = nil, format: Format? = nil
    ) {
        self.stream = stream
        self.generation = generation
        self.codec = codec
        self.payload = payload
        self.isRandomAccess = isRandomAccess
        self.parameterSets = parameterSets
        self.hostArrival = hostArrival
        self.presentationTime = presentationTime
        self.format = format
    }

    /// An H.26x access unit. Random access and parameter sets come from its NAL headers; a unit
    /// without in-band parameter sets keeps `previousParameterSets` (the stream's current ones).
    public init(
        stream: StreamID, generation: StreamGeneration, annexB: [UInt8], codec: LiveVideoCodec,
        previousParameterSets: [[UInt8]], hostArrival: TimeInterval,
        presentationTime: TimeInterval? = nil, format: Format? = nil
    ) {
        let sets = Hevc.nalRanges(annexB).filter { range in
            let first = annexB[range.lowerBound]
            switch codec {
            case .hevc: return [Hevc.vps, Hevc.sps, Hevc.pps].contains(Hevc.nalType(first))
            case .avc: return [Avc.sps, Avc.pps].contains(Avc.nalType(first))
            }
        }.map { Array(annexB[$0]) }
        self.init(
            stream: stream, generation: generation, codec: Codec(codec), payload: annexB,
            isRandomAccess: LiveVideo.accessUnitCarriesKeyframe(annexB, codec: codec),
            parameterSets: sets.isEmpty ? previousParameterSets : sets,
            hostArrival: hostArrival, presentationTime: presentationTime, format: format)
    }
}
