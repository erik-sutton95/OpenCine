import Foundation
import MonitorPresentation
import MonitorUI
import Testing

/// The platform notices an app shows are the repository files themselves (Kotlin twin:
/// MonitorLegalDocumentsTest).
@Suite struct MonitorPlatformLegalNoticesTests {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    @Test func theBundledNoticesCopyIsTheRepositoryFileByteForByte() throws {
        #expect(try read("Sources/MonitorUI/Resources/Legal/THIRD-PARTY-NOTICES.md") == read("THIRD-PARTY-NOTICES.md"))
    }

    @Test func thePlatformNoticesAreTheRepositoryNoticesAndTheSharedUILicenseTexts() throws {
        let expected = try [
            "THIRD-PARTY-NOTICES.md", "Sources/MonitorUI/Resources/Fonts/OFL-Sora.txt",
            "Sources/MonitorUI/Resources/Icons/lucide/LICENSE.txt",
            "Sources/MonitorUI/Resources/Icons/assist/LICENSE-Tabler.txt",
        ].map { try read($0).trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
        #expect(MonitorPlatformLegalNotices.document == .text(expected))
        #expect(MonitorPlatformLegalNotices.text == expected)
    }

    @Test func aMissingOrBlankBundledFileIsUnavailableNeverEmpty() {
        #expect(MonitorLegalDocuments.bundledText(["NOTICE", nil]) == .unavailable)
        #expect(MonitorLegalDocuments.bundledText(["  \n"]) == .unavailable)
        #expect(MonitorLegalDocuments.bundledText([]) == .unavailable)
        #expect(MonitorLegalDocuments.bundledText(["A\n", "B"]) == .text("A\n\nB"))
        let terms = URL(string: "https://example.org/terms")!
        let documents = MonitorLegalDocuments(wordmark: "W", privacy: .text("P"), terms: .link(terms),
            licenses: .unavailable, notice: .text("N"))
        #expect(documents[.terms] == .link(terms))
        #expect(documents[.licenses] == .unavailable)
        #expect(MonitorLegalPage.allCases.map(\.title) == ["Privacy", "Terms", "Licenses", "NOTICE"])
    }
}
