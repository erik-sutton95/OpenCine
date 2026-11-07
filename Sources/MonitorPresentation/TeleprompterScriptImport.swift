import Foundation

/// A readable script copied onto the device, independent of its original file or network.
public struct TeleprompterScript: Equatable, Sendable, Codable {
    /// Plain text displayed by the reader.
    public let text: String
    /// Filename or human-readable source name.
    public let name: String
    /// Original HTTPS source, retained only for an explicit refresh.
    public let sourceURL: URL?

    /// Creates a locally readable script with optional refresh metadata.
    public init(text: String, name: String, sourceURL: URL? = nil) {
        self.text = text
        self.name = name
        self.sourceURL = sourceURL
    }
}

/// Import failures leave the previously accepted script intact.
public enum TeleprompterScriptImportError: Error, LocalizedError, Sendable {
    case tooLarge, invalidEncoding, empty, unsupportedFormat, webPage, invalidLink

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "Choose a script smaller than 1 MiB."
        case .invalidEncoding: "Choose a UTF-8 text or Markdown file."
        case .empty: "The script does not contain any readable text."
        case .unsupportedFormat: "Choose a .txt or .md file, or a direct text or Markdown link."
        case .webPage: "This link opens a webpage. Use a direct text or Markdown download link."
        case .invalidLink: "Enter a public HTTPS link to a text or Markdown script."
        }
    }
}

/// Bounded decoding and text preparation shared by the script editor and reader.
public enum TeleprompterScriptImport {
    /// Maximum source size for pasted text, files and downloaded scripts.
    public static let maximumBytes: Int = 1_048_576

    /// Decodes a UTF-8 text or Markdown source without performing file or network I/O.
    public static func decode(
        _ data: Data, name: String, sourceURL: URL? = nil, contentType: String? = nil
    ) throws -> TeleprompterScript {
        guard data.count <= maximumBytes else { throw TeleprompterScriptImportError.tooLarge }
        guard let decoded = String(data: data, encoding: .utf8), !decoded.contains("\0") else {
            throw TeleprompterScriptImportError.invalidEncoding
        }
        let text = normalized(decoded)
        let mime = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
            .lowercased()
        let prefix = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mime == "text/html" || mime == "application/xhtml+xml"
            || (sourceURL != nil
                && ["<!doctype html", "<html", "<head", "<body"].contains(where: prefix.hasPrefix))
        {
            throw TeleprompterScriptImportError.webPage
        }
        if let mime,
            !["text/plain", "text/markdown", "text/x-markdown", "application/octet-stream"]
                .contains(mime)
        {
            throw TeleprompterScriptImportError.unsupportedFormat
        }
        let ext = (name as NSString).pathExtension.lowercased()
        let isMarkdown = ext == "md" || ["text/markdown", "text/x-markdown"].contains(mime)
        guard isMarkdown || ext == "txt" || mime == "text/plain" else {
            throw TeleprompterScriptImportError.unsupportedFormat
        }
        let readable = isMarkdown ? markdownText(text) : text
        try requireText(readable)
        return TeleprompterScript(text: readable, name: name, sourceURL: sourceURL)
    }

    /// Accepts explicitly pasted or edited text, preserving paragraph breaks.
    public static func paste(_ text: String) throws -> TeleprompterScript {
        guard text.utf8.count <= maximumBytes else { throw TeleprompterScriptImportError.tooLarge }
        let readable = normalized(text)
        guard !readable.contains("\0") else { throw TeleprompterScriptImportError.invalidEncoding }
        try requireText(readable)
        return TeleprompterScript(text: readable, name: "Pasted script")
    }

    /// Validates a direct public HTTPS source; no authentication or webpage extraction occurs.
    public static func link(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
            url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
            url.user == nil, url.password == nil
        else { throw TeleprompterScriptImportError.invalidLink }
        return url
    }

    private static func normalized(_ text: String) -> String {
        let source = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        return source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func requireText(_ text: String) throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TeleprompterScriptImportError.empty
        }
    }

    private static func replace(_ text: String, _ pattern: String, _ value: String) -> String {
        text.replacingOccurrences(of: pattern, with: value, options: .regularExpression)
    }

    private static func markdownText(_ text: String) -> String {
        var fence: Character?
        return text.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = fence {
                if trimmed.hasPrefix(String(repeating: String(current), count: 3)) {
                    fence = nil
                    return nil
                }
                return line
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = trimmed.first
                return nil
            }
            if trimmed.range(of: #"^(?:=+|-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression)
                != nil
            {
                return nil
            }
            var readable = replace(line, #"^\s{0,3}#{1,6}\s+(.+?)(?:\s+#+)?\s*$"#, "$1")
            readable = replace(readable, #"^\s{0,3}(?:>\s?)+"#, "")
            readable = replace(readable, #"^\s*[-+*]\s+(?:\[[ xX]\]\s+)?"#, "• ")
            readable = replace(readable, #"!?\[([^\]]*)\]\([^\n)]*\)"#, "$1")
            if !readable.contains("`") {
                readable = replace(readable, #"</?[A-Za-z][A-Za-z0-9]*(?:\s[^<>]*)?/?>"#, "")
            }
            readable = replace(readable, #"(?<!\\)(\*\*|__)(?=\S)(.+?)\1"#, "$2")
            readable = replace(readable, #"(?<![\\\w])([*_])(?=\S)(.+?)(?<=\S)\1(?!\w)"#, "$2")
            readable = replace(readable, #"(`+)(.+?)\1"#, "$2")
            return replace(readable, #"\\([\\`*_{}\[\]()#+.!>\-])"#, "$1")
        }.joined(separator: "\n")
    }
}
