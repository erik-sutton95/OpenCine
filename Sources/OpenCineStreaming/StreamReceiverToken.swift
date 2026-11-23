import Foundation

/// The stream key a camera is told to publish under, fresh for every session, so the receiver on
/// this device accepts only the camera it provisioned. Never logged in full: `logLabel` and
/// `description` show its first 4 characters.
public struct StreamReceiverToken: Hashable, Sendable, CustomStringConvertible {
    /// 32 lowercase hexadecimal characters (128 random bits).
    public let value: String

    public init(value: String) { self.value = value }

    public static func random() -> StreamReceiverToken {
        var generator = SystemRandomNumberGenerator()
        let hex = (0..<16).map { _ in
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            return String(byte, radix: 16).count == 1 ? "0" + String(byte, radix: 16) : String(byte, radix: 16)
        }
        return StreamReceiverToken(value: hex.joined())
    }

    public var logLabel: String { String(value.prefix(4)) + "****" }

    public var description: String { logLabel }

    /// The address the camera publishes to: `rtmp://<host>:<port>/live/<token>`.
    public func publishURL(host: String, port: UInt16 = 1935) -> String {
        "rtmp://\(host):\(port)/live/\(value)"
    }
}
