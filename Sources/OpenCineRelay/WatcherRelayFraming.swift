import Foundation

/// `[u32be payload length][u8 kind][payload]`. Length includes the kind byte.
public enum WatcherRelayFraming: Sendable {
    public static let headerBytes = 5

    public static func encode(kind: WatcherRelayProtocol.Kind, payload: Data) -> Data {
        RelayStreamFraming.encode(kind: kind.rawValue, payload: payload)
    }

    public struct Decoded: Equatable, Sendable {
        public var kind: WatcherRelayProtocol.Kind
        public var payload: Data
        public var consumedBytes: Int
        public init(kind: WatcherRelayProtocol.Kind, payload: Data, consumedBytes: Int) {
            self.kind = kind
            self.payload = payload
            self.consumedBytes = consumedBytes
        }
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case payloadTooLarge(declared: Int)
        case unknownKind(UInt8)
    }

    public static func decode(from buffer: Data) throws -> Decoded? {
        do {
            guard let decoded = try RelayStreamFraming.decode(from: buffer, profile: .sharedMonitor)
            else { return nil }
            guard let kind = WatcherRelayProtocol.Kind(rawValue: decoded.kind) else {
                throw DecodeError.unknownKind(decoded.kind)
            }
            return Decoded(
                kind: kind, payload: decoded.payload, consumedBytes: decoded.consumedBytes)
        } catch let error as RelayStreamFraming.DecodeError {
            switch error {
            case .payloadTooLarge(let declared):
                throw DecodeError.payloadTooLarge(declared: declared)
            case .unknownKind(let kind): throw DecodeError.unknownKind(kind)
            }
        }
    }
}
