#if canImport(Network)
    import Foundation
    import Network
    import OpenCineRelay

    /// TCP framing and HEVC copies stay off MainActor. One receive batch at a time: the next
    /// read waits for consumption, so a busy decoder cannot accumulate unbounded actor tasks.
    public final class WatcherRelayReader: @unchecked Sendable {
        public enum Message: Sendable {
            case control(WatcherRelayFraming.Decoded)
            case frame(WatcherRelayFrameMetadata, [UInt8])
        }

        private let reader = RelayAppleReader(codec: SharedMonitorRelayCodec())
        public var queue: DispatchQueue { reader.queue }
        /// The legacy callback is delivered serially on its connection queue, as before.
        private final class Completion: @unchecked Sendable {
            let body: ([Message], Bool, Error?) -> Void
            init(_ body: @escaping ([Message], Bool, Error?) -> Void) { self.body = body }
        }

        public init() {}

        public func receive(
            on connection: NWConnection,
            completion: @escaping ([Message], Bool, Error?) -> Void
        ) {
            let callback = Completion(completion)
            reader.receive(on: connection) { batch, complete, error in
                do {
                    let messages = try batch.map { value -> Message in
                        switch value {
                        case .frame(let metadata, let bytes):
                            return .frame(metadata, [UInt8](bytes))
                        case .control(let message):
                            guard let kind = WatcherRelayProtocol.Kind(rawValue: message.kind)
                            else {
                                throw WatcherRelayFraming.DecodeError.unknownKind(message.kind)
                            }
                            return .control(
                                .init(
                                    kind: kind, payload: message.payload,
                                    consumedBytes: message.consumedBytes))
                        }
                    }
                    callback.body(messages, complete, Self.legacyError(error))
                } catch {
                    callback.body([], true, Self.legacyError(error))
                }
            }
        }

        private static func legacyError(_ error: Error?) -> Error? {
            switch error {
            case let error as RelayStreamFraming.DecodeError:
                switch error {
                case .payloadTooLarge(let declared):
                    return WatcherRelayFraming.DecodeError.payloadTooLarge(declared: declared)
                case .unknownKind(let kind):
                    return WatcherRelayFraming.DecodeError.unknownKind(kind)
                }
            case let error as RelayFrameBlob.DecodeError:
                switch error {
                case .truncated(let declared):
                    return WatcherRelayFraming.DecodeError.payloadTooLarge(declared: declared)
                }
            default: return error
            }
        }
    }
#endif
