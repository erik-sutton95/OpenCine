#if DEBUG
    import Foundation
    import Insta360Protocol
    import OpenCineMedia

    /// A SIMULATED Luna camera behind `LunaCameraBackend`'s control link (`connect(review:)`), for the
    /// apps' Debug review harnesses. Its card holds `clips`; it answers the media commands (album
    /// access, live stop and start, file list, file info, delete) in the camera's own reply encodings,
    /// so the real session, media service and browse run over it. Every other command is refused as
    /// the camera refuses one (status 500): live controls never take effect. Never touches a network;
    /// compiled out of Release builds.
    @MainActor public final class LunaReviewCamera {
        /// One clip on the camera's inner storage (location 2), as `GetFileInfoList` describes it.
        public struct Clip: Equatable, Sendable {
            public var uri: String
            public var byteCount: UInt64
            public var milliseconds: UInt64
            public var width: Int
            public var height: Int
            public var fps: UInt64
            /// Local wall time, decimal yyyyMMddHHmmss.
            public var stamp: UInt64?

            public init(
                uri: String, byteCount: UInt64, milliseconds: UInt64, width: Int, height: Int, fps: UInt64,
                stamp: UInt64?
            ) {
                self.uri = uri
                self.byteCount = byteCount
                self.milliseconds = milliseconds
                self.width = width
                self.height = height
                self.fps = fps
                self.stamp = stamp
            }
        }

        /// The card (the shared SIMULATED `ReviewCard`): a delete removes the clip it names.
        public let card: ReviewCard<Clip>
        /// The card's clips. A harness may stage them after the camera connects.
        public var clips: [Clip] {
            get { card.clips }
            set { card.clips = newValue }
        }
        /// Every request the link carried, in order.
        public private(set) var received: [LunaRequest] = []

        public init(clips: [Clip]) { card = ReviewCard(clips: clips) }

        func answer(_ request: LunaRequest) throws -> Data {
            received.append(request)
            let body = try ProtoMessage(request.body)
            switch request.command {
            case .setAccessCameraFileState, .startLive, .stopLive: return Data()
            case .getFileList:
                let listed = try clips(at: body.unsigned(4, default: 2))
                return try listed.reduce(into: Data()) { $0 += try ProtoMessage.blob(field: 1, value: Data($1.uri.utf8)) }
                    + ProtoMessage.integer(field: 2, value: UInt64(listed.count))
            case .getFileInfoList:
                return try clips(at: body.unsigned(1, default: 2)).reduce(into: Data()) { reply, clip in
                    let info = try ProtoMessage.blob(field: 1, value: Data(clip.uri.utf8))
                        + ProtoMessage.blob(field: 2, value: metadata(clip))
                    reply += try ProtoMessage.blob(field: 1, value: info)
                }
            case .deleteFiles:
                let uri = try body.string(1)
                guard card.delete(where: { $0.uri == uri }) else { throw LunaProtocolError.cameraRejectedRequest }
                return Data()
            default: throw LunaProtocolError.cameraRejectedRequest
            }
        }

        private func clips(at location: UInt64) -> [Clip] { location == 2 ? clips : [] }

        private func metadata(_ clip: Clip) throws -> Data {
            var data = Data()
            if let stamp = clip.stamp { data += try ProtoMessage.integer(field: 7, value: stamp) }
            data += try ProtoMessage.integer(field: 9, value: clip.byteCount)
            data += try ProtoMessage.integer(field: 10, value: clip.milliseconds / 1000)
            data += try ProtoMessage.blob(
                field: 19,
                value: ProtoMessage.integer(field: 1, value: UInt64(clip.width))
                    + ProtoMessage.integer(field: 2, value: UInt64(clip.height)))
            data += try ProtoMessage.integer(field: 20, value: clip.fps)
            data += try ProtoMessage.blob(field: 26, value: ProtoMessage.integer(field: 1, value: 0))
            data += try ProtoMessage.integer(field: 93, value: clip.milliseconds)
            return data
        }
    }
#endif
