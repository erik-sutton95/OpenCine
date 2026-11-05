import Foundation

public struct WindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum ModuleStatus: Codable, Equatable, Sendable {
    case idle
    case connecting
    case live(cameraName: String?)
    case failed(String)
}

/// From the dock to a module.
public enum DockMessage: Codable, Equatable, Sendable {
    case show(frame: WindowFrame)
    case hide
    case quit
}

/// From a module to the dock.
public enum ModuleMessage: Codable, Equatable, Sendable {
    case ready(moduleID: String)
    case status(ModuleStatus)
}

public enum LengthPrefixedJSONError: Error, Equatable, Sendable {
    case messageTooLarge
}

/// Four-byte big-endian length, then JSON. Reads tolerate messages split at any byte.
public enum LengthPrefixedJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder().encode(value)
        var length = UInt32(body.count).bigEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Removes and decodes every complete message in `buffer`, leaving any partial one.
    public static func decodeAll<T: Decodable>(
        _ buffer: inout Data, maxMessageBytes: Int = 64 * 1024
    ) throws -> [T] {
        var messages: [T] = []
        while buffer.count >= 4 {
            let start = buffer.startIndex
            let length = buffer[start..<(start + 4)].reduce(0) { $0 << 8 | Int($1) }
            guard length <= maxMessageBytes else { throw LengthPrefixedJSONError.messageTooLarge }
            guard buffer.count >= 4 + length else { break }
            messages.append(
                try JSONDecoder().decode(T.self, from: buffer[(start + 4)..<(start + 4 + length)]))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return messages
    }
}
