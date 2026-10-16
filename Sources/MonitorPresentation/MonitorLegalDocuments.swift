import Foundation

/// The four legal pages every app offers, in Settings and wherever privacy is linked.
public enum MonitorLegalPage: String, CaseIterable, Identifiable, Sendable {
    case privacy, terms, licenses, notice

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .privacy: "Privacy"
        case .terms: "Terms"
        case .licenses: "Licenses"
        case .notice: "NOTICE"
        }
    }
}

/// One legal page: text bundled with the app (readable offline), a page opened in the browser, or
/// bundled text this build does not carry. Unavailable is stated, never shown as an empty page.
public enum MonitorLegalDocument: Equatable, Sendable {
    case text(String)
    case link(URL)
    case unavailable
}

/// An app's legal set. Privacy and terms may be bundled text or web pages; license and attribution
/// text is bundled from the repository's own files, so it is reachable without a network and never
/// drifts from what ships.
public struct MonitorLegalDocuments: Equatable, Sendable {
    public let wordmark: String
    public let privacy: MonitorLegalDocument
    public let terms: MonitorLegalDocument
    public let licenses: MonitorLegalDocument
    public let notice: MonitorLegalDocument

    public init(
        wordmark: String, privacy: MonitorLegalDocument, terms: MonitorLegalDocument,
        licenses: MonitorLegalDocument, notice: MonitorLegalDocument
    ) {
        self.wordmark = wordmark; self.privacy = privacy; self.terms = terms
        self.licenses = licenses; self.notice = notice
    }

    public subscript(page: MonitorLegalPage) -> MonitorLegalDocument {
        switch page {
        case .privacy: privacy
        case .terms: terms
        case .licenses: licenses
        case .notice: notice
        }
    }

    /// What a page this build does not carry says.
    public static let unavailableText =
        "This build does not include this document. It is in the project's source repository."

    /// The named bundled files joined in order, or unavailable when any one is missing or empty.
    public static func bundledText(_ parts: [String?]) -> MonitorLegalDocument {
        let texts = parts.map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        guard !texts.isEmpty, texts.allSatisfy({ !$0.isEmpty }) else { return .unavailable }
        return .text(texts.joined(separator: "\n\n"))
    }

    /// The UTF-8 text of one bundled resource, or nil when the build does not carry it.
    public static func resource(_ name: String, extension ext: String? = nil, subdirectory: String? = nil,
        in bundle: Bundle) -> String? {
        bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
