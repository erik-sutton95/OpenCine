import Foundation

/// Why a server address or stream key cannot be used.
public enum StreamDestinationError: Error, Equatable, Sendable {
    /// The server address is not `rtmps://`. Plain `rtmp://` is refused unless the caller allows it
    /// (a Custom server); any other scheme is always refused.
    case notRTMPS
    /// The server address has no host, an invalid port or no application path.
    case invalidServerURL
    /// The stream key is empty after trimming.
    case emptyKey
    /// The stream key holds `://`, so a whole URL was pasted into the key field.
    case keyLooksLikeURL
}

/// Where a stream goes: an `rtmps://` server (or, for a Custom server only, a plain `rtmp://` one)
/// and the stream key that names the stream there.
///
/// The key is a secret. It is readable only through `streamKey`, and appears in no description,
/// debug description or mirror. It is deliberately not `Codable`: hosts keep it in secure storage.
public struct StreamDestination: Hashable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    public let host: String
    public let port: UInt16
    /// The application path, without outer slashes. May hold several segments.
    public let app: String
    /// The `tcUrl` the `connect` command carries: scheme, host, port and application.
    public let tcURL: String
    /// The secret stream key. The only way to read it.
    public let streamKey: String
    /// `true` for `rtmps://` (TLS). `false` only for a plain `rtmp://` address the caller allowed:
    /// the stream and its key then travel unencrypted, and the operator must be told so.
    public let isEncrypted: Bool

    /// Parses a pasted server address and key. Surrounding whitespace is trimmed from both.
    /// `rtmps://` defaults to port 443. With `allowsPlainRTMP`, a plain `rtmp://` address is also
    /// accepted (port 1935 by default); only a Custom server allows it, never a service preset.
    public init(serverURL: String, streamKey: String, allowsPlainRTMP: Bool = false) throws {
        let lowered = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if allowsPlainRTMP, lowered.hasPrefix("rtmp://") {
            try self.init(serverURL: serverURL, streamKey: streamKey, scheme: "rtmp", defaultPort: 1935)
        } else {
            try self.init(serverURL: serverURL, streamKey: streamKey, scheme: "rtmps", defaultPort: 443)
        }
    }

    /// The destination for a preset: its fixed server, or the entered one when the preset asks
    /// for entry, with the preset's rule on plain `rtmp://`. A missing entry is `invalidServerURL`.
    public init(preset: StreamServicePreset, enteredServerURL: String?, streamKey: String) throws {
        guard let server = preset.requiresServerEntry ? enteredServerURL : preset.serverURL else {
            throw StreamDestinationError.invalidServerURL
        }
        try self.init(serverURL: server, streamKey: streamKey, allowsPlainRTMP: preset.allowsPlainRTMP)
    }

    private init(serverURL: String, streamKey: String, scheme: String, defaultPort: UInt16) throws {
        let url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = scheme + "://"
        guard url.lowercased().hasPrefix(prefix) else {
            if url.lowercased().hasPrefix("rtmp://") || url.lowercased().hasPrefix("rtmps://") {
                throw StreamDestinationError.notRTMPS
            }
            throw url.contains("://") ? StreamDestinationError.notRTMPS : StreamDestinationError.invalidServerURL
        }
        let rest = url.dropFirst(prefix.count)
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let authority = rest[rest.startIndex..<slash]
        let path = rest[slash...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let (host, port) = try Self.parseAuthority(authority, defaultPort: defaultPort)
        guard !path.isEmpty, !path.contains(where: { $0.isWhitespace }) else {
            throw StreamDestinationError.invalidServerURL
        }
        let key = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw StreamDestinationError.emptyKey }
        guard !key.contains("://") else { throw StreamDestinationError.keyLooksLikeURL }

        self.host = host
        self.port = port
        self.app = path
        let hostPart = host.contains(":") ? "[\(host)]" : host
        self.tcURL = "\(scheme)://\(hostPart):\(port)/\(path)"
        self.streamKey = key
        self.isEncrypted = scheme == "rtmps"
    }

    private static func parseAuthority(_ authority: Substring, defaultPort: UInt16) throws -> (String, UInt16) {
        var host: Substring
        var portText: Substring?
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { throw StreamDestinationError.invalidServerURL }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let after = authority[authority.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { throw StreamDestinationError.invalidServerURL }
                portText = after.dropFirst()
            }
        } else if let colon = authority.firstIndex(of: ":") {
            host = authority[authority.startIndex..<colon]
            portText = authority[authority.index(after: colon)...]
        } else {
            host = authority
        }
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "@" }) else {
            throw StreamDestinationError.invalidServerURL
        }
        var port = defaultPort
        if let portText {
            guard let value = UInt16(portText), value > 0 else { throw StreamDestinationError.invalidServerURL }
            port = value
        }
        return (String(host), port)
    }

    public var description: String { "StreamDestination(\(tcURL))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["host": host, "port": port, "app": app], displayStyle: .struct)
    }
}
