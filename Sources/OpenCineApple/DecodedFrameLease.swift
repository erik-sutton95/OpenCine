#if canImport(CoreVideo)
    import CoreVideo
    import Foundation
    import OpenCineCore

    /// Raster and pixel layout of a decoded surface.
    public struct DecodedFrameFormat: Equatable, Sendable {
        public let width: Int
        public let height: Int
        /// CoreVideo pixel format (`kCVPixelFormatType_*`).
        public let pixelFormat: OSType

        public init(width: Int, height: Int, pixelFormat: OSType) {
            self.width = width
            self.height = height
            self.pixelFormat = pixelFormat
        }

        public init(_ buffer: CVPixelBuffer) {
            self.init(
                width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                pixelFormat: CVPixelBufferGetPixelFormatType(buffer))
        }
    }

    /// One decoded picture on loan from its source (plan 6.1, MEDIA-02).
    ///
    /// Carries the stream, the generation it was decoded in and its format next to the native
    /// surface. The lease holds its `CVPixelBuffer` until `release()`; afterwards `pixelBuffer`
    /// is nil. A consumer that needs pixels after the callback that lent it the lease returns
    /// takes its own reference to `pixelBuffer`. Publishing goes through `DecodedFrameFence`,
    /// which refuses (and releases) a lease from an older generation.
    public final class DecodedFrameLease: @unchecked Sendable {
        public let stream: StreamID
        public let generation: StreamGeneration
        public let format: DecodedFrameFormat
        /// Host monotonic nanoseconds of the source picture; 0 when the source did not say.
        public let timeNs: Int64
        private let lock = NSLock()
        private var buffer: CVPixelBuffer?

        public init(
            _ buffer: CVPixelBuffer, stream: StreamID, generation: StreamGeneration,
            timeNs: Int64 = 0
        ) {
            self.stream = stream
            self.generation = generation
            self.format = DecodedFrameFormat(buffer)
            self.timeNs = timeNs
            self.buffer = buffer
        }

        /// The surface, or nil once released.
        public var pixelBuffer: CVPixelBuffer? { lock.withLock { buffer } }

        public var isReleased: Bool { lock.withLock { buffer == nil } }

        /// Drops the lease's reference to the surface. Idempotent; safe from any thread.
        public func release() {
            let dropped = lock.withLock { () -> CVPixelBuffer? in
                defer { buffer = nil }
                return buffer
            }
            _ = dropped
        }
    }

    /// The current generation of one decoded stream and the gate every publication passes.
    ///
    /// `advance()` (decoder reset, session rebuild, reconfiguration) makes every outstanding
    /// lease and in-flight decode stale. Thread-safe: decoder callbacks read it off the main
    /// actor. A generation that advances while a consumer runs is caught by the next check; an
    /// owner that advances and publishes on the same actor gets an exact answer.
    public final class DecodedFrameFence: @unchecked Sendable {
        public let stream: StreamID
        private let lock = NSLock()
        private var current: StreamGeneration

        public init(stream: StreamID = StreamID(), generation: StreamGeneration = StreamGeneration())
        {
            self.stream = stream
            self.current = generation
        }

        public var generation: StreamGeneration { lock.withLock { current } }

        /// Starts a new generation; everything stamped earlier is stale.
        @discardableResult
        public func advance() -> StreamGeneration {
            lock.withLock {
                current = current.next()
                return current
            }
        }

        public func isCurrent(_ generation: StreamGeneration) -> Bool {
            lock.withLock { current == generation }
        }

        /// A lease on `buffer` stamped with `generation` (the current one when nil).
        public func lease(
            _ buffer: CVPixelBuffer, generation: StreamGeneration? = nil, timeNs: Int64 = 0
        ) -> DecodedFrameLease {
            DecodedFrameLease(
                buffer, stream: stream, generation: generation ?? self.generation, timeNs: timeNs)
        }

        /// Lends `lease` to `consumer` when it belongs to this stream's current generation and
        /// is still held. Anything else is released and refused, never published.
        @discardableResult
        public func publish(_ lease: DecodedFrameLease, to consumer: (DecodedFrameLease) -> Void)
            -> Bool
        {
            guard lease.stream == stream, isCurrent(lease.generation), !lease.isReleased else {
                lease.release()
                return false
            }
            consumer(lease)
            return true
        }
    }
#endif
