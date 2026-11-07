import Foundation
import Testing

@testable import MonitorPresentation

struct TeleprompterScriptImportTests {
    @Test func textFilesRetainUnicodeParagraphsAndRefreshSource() throws {
        let source = try TeleprompterScriptImport.link(" https://example.com/script.txt?version=2 ")
        let script = try TeleprompterScriptImport.decode(
            Data("\u{FEFF}Café 🎬\r\n\r\nSecond paragraph.\r".utf8), name: "script.TXT",
            sourceURL: source)
        #expect(script.text == "Café 🎬\n\nSecond paragraph.\n")
        #expect(script.name == "script.TXT")
        #expect(script.sourceURL == source)
    }

    @Test func markdownBecomesReadableScriptWhileCodeContentSurvives() throws {
        let script = try TeleprompterScriptImport.decode(
            Data(
                """
                # Welcome

                Hello **camera**, _team_ and `crew`.
                - [ ] Check [framing](https://example.com).
                > Keep **rolling**.

                ```swift
                let cue = "**literal**"
                ```
                """.utf8), name: "script.md")
        #expect(
            script.text == """
                Welcome

                Hello camera, team and crew.
                • Check framing.
                Keep rolling.

                let cue = "**literal**"
                """)
        let literal = try TeleprompterScriptImport.decode(
            Data(#"\*literal\* and snake_case_value"#.utf8), name: "script.md")
        #expect(literal.text == "*literal* and snake_case_value")
    }

    @Test func directDownloadsCanDeclareFormatWithTheirContentType() throws {
        let script = try TeleprompterScriptImport.decode(
            Data("# Title\nText".utf8), name: "download",
            contentType: "text/markdown; charset=utf-8")
        #expect(script.text == "Title\nText")
    }

    @Test func markdownLayoutTagsAreOmittedWhileCodeAndAutolinksRemainReadable() throws {
        let script = try TeleprompterScriptImport.decode(
            Data(
                "<div align=\"center\">\n# Welcome\nHello <strong>team</strong>.\n</div>\n`<div>`\n<https://example.com>"
                    .utf8),
            name: "script.md")
        #expect(script.text == "\nWelcome\nHello team.\n\n<div>\n<https://example.com>")
    }

    @Test(arguments: ["application/json", "application/pdf", "text/csv"])
    func fileExtensionsDoNotOverrideUnsupportedContentTypes(contentType: String) {
        #expect(throws: TeleprompterScriptImportError.self) {
            try TeleprompterScriptImport.decode(
                Data("Readable bytes".utf8), name: "script.txt", contentType: contentType)
        }
    }

    @Test func unsupportedEmptyAndBinarySourcesFailBeforeAcceptance() {
        #expect(throws: TeleprompterScriptImportError.self) {
            try TeleprompterScriptImport.decode(Data([0xFF]), name: "bad.txt")
        }
        #expect(throws: TeleprompterScriptImportError.self) {
            try TeleprompterScriptImport.decode(Data("\0binary".utf8), name: "bad.txt")
        }
        #expect(throws: TeleprompterScriptImportError.self) {
            try TeleprompterScriptImport.decode(Data("Text".utf8), name: "script.pdf")
        }
        #expect(throws: TeleprompterScriptImportError.self) {
            try TeleprompterScriptImport.paste(" \n\t")
        }
    }

    @Test func webPagesAndOversizedScriptsAreRejected() throws {
        let url = try TeleprompterScriptImport.link("https://example.com/script.txt")
        #expect(throws: TeleprompterScriptImportError.self) {
            try TeleprompterScriptImport.decode(
                Data("<html>Sign in</html>".utf8), name: "script.txt", sourceURL: url)
        }
        #expect(throws: TeleprompterScriptImportError.self) {
            try TeleprompterScriptImport.decode(
                Data("Text".utf8), name: "script.txt", contentType: "text/html")
        }
        #expect(throws: TeleprompterScriptImportError.self) {
            try TeleprompterScriptImport.paste(
                String(repeating: "a", count: TeleprompterScriptImport.maximumBytes + 1))
        }
    }

    @Test(arguments: [
        "http://example.com/script.txt", "file:///script.txt", "https://",
        "https://user:password@example.com/script.txt",
    ])
    func onlyPublicHTTPSLinksAreAccepted(value: String) {
        #expect(throws: TeleprompterScriptImportError.self) {
            try TeleprompterScriptImport.link(value)
        }
    }
}
