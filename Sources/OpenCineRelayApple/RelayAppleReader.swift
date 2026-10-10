#if canImport(Network)
    import Foundation
    import Network
    import OpenCineRelay

    /// One serial SDK receive owner. Typed frame parsing/copies stay off the operator actor;
    /// the caller admits the next batch only after consumption of this one.
    public final class RelayAppleReader<Codec: RelayWireCodec>: @unchecked Sendable {
        public enum Message: Sendable {
            case control(RelayStreamFraming.Decoded)
            case frame(Codec.FrameMetadata, Data)
        }
        public let queue = DispatchQueue(label: "opc.relay.receive", qos: .userInitiated)
        private let codec: Codec
        private let maximumReceiveBytes: Int
        private var stream: RelayStreamBuffer
        public init(codec: Codec, maximumReceiveBytes: Int = 256 * 1024) {
            self.codec = codec
            self.maximumReceiveBytes = maximumReceiveBytes
            stream = RelayStreamBuffer(profile: codec.profile)
        }
        public func receive(
            on connection: NWConnection,
            completion: @escaping @Sendable ([Message], Bool, Error?) -> Void
        ) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumReceiveBytes) {
                [self] bytes, _, complete, error in
                do {
                    let messages = try stream.append(bytes ?? Data()).map { message -> Message in
                        if message.kind == 3 {
                            let frame = try codec.decodeFrame(message.payload)
                            return .frame(frame.metadata, frame.image)
                        }
                        return .control(message)
                    }
                    completion(messages, complete, error)
                } catch { completion([], true, error) }
            }
        }
    }
#endif
