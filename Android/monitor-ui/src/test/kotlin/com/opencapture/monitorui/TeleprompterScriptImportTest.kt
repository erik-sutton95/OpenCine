package com.opencapture.monitorui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class TeleprompterScriptImportTest {
    @Test fun textRetainsUnicodeParagraphsAndRefreshSource() {
        val url = TeleprompterScriptImport.link(" https://example.com/script.txt?version=2 ")
        val script = TeleprompterScriptImport.decode("\uFEFFCafé 🎬\r\n\r\nSecond paragraph.\r".toByteArray(), "script.TXT", url)
        assertEquals("Café 🎬\n\nSecond paragraph.\n", script.text)
        assertEquals(url, script.sourceUrl)
    }

    @Test fun markdownBecomesReadableWhileCodeSurvives() {
        val input = "# Welcome\n\nHello **camera**, _team_ and `crew`.\n- [ ] Check [framing](https://example.com).\n> Keep **rolling**.\n\n```swift\nlet cue = \"**literal**\"\n```"
        val expected = "Welcome\n\nHello camera, team and crew.\n• Check framing.\nKeep rolling.\n\nlet cue = \"**literal**\""
        assertEquals(expected, TeleprompterScriptImport.decode(input.toByteArray(), "script.md").text)
        assertEquals("*literal* and snake_case_value", TeleprompterScriptImport.decode("\\*literal\\* and snake_case_value".toByteArray(), "script.md").text)
    }

    @Test fun downloadCanDeclareMarkdownWithItsContentType() {
        assertEquals("Title\nText", TeleprompterScriptImport.decode("# Title\nText".toByteArray(), "download", contentType = "text/markdown; charset=utf-8").text)
    }

    @Test fun markdownOmitsLayoutTagsAndKeepsCodeAndAutolinks() {
        val source = "<div align=\"center\">\n# Welcome\nHello <strong>team</strong>.\n</div>\n`<div>`\n<https://example.com>"
        assertEquals("\nWelcome\nHello team.\n\n<div>\n<https://example.com>",
            TeleprompterScriptImport.decode(source.toByteArray(), "script.md").text)
    }

    @Test fun extensionsDoNotOverrideUnsupportedContentTypes() {
        for (type in listOf("application/json", "application/pdf", "text/csv")) {
            assertThrows(TeleprompterScriptImportException::class.java) {
                TeleprompterScriptImport.decode("Readable bytes".toByteArray(), "script.txt", contentType = type)
            }
        }
    }

    @Test fun invalidSourcesAreRejectedBeforeAcceptance() {
        assertThrows(TeleprompterScriptImportException::class.java) { TeleprompterScriptImport.decode(byteArrayOf(-1), "bad.txt") }
        assertThrows(TeleprompterScriptImportException::class.java) { TeleprompterScriptImport.decode("\u0000binary".toByteArray(), "bad.txt") }
        assertThrows(TeleprompterScriptImportException::class.java) { TeleprompterScriptImport.decode("Text".toByteArray(), "script.pdf") }
        assertThrows(TeleprompterScriptImportException::class.java) { TeleprompterScriptImport.paste(" \n\t") }
        assertThrows(TeleprompterScriptImportException::class.java) { TeleprompterScriptImport.decode("<html>Sign in</html>".toByteArray(), "script.txt", "https://example.com/script.txt") }
        assertThrows(TeleprompterScriptImportException::class.java) { TeleprompterScriptImport.decode("Text".toByteArray(), "script.txt", contentType = "text/html") }
        assertThrows(TeleprompterScriptImportException::class.java) { TeleprompterScriptImport.paste("a".repeat(TeleprompterScriptImport.MAXIMUM_BYTES + 1)) }
    }

    @Test fun onlyPublicHTTPSLinksAreAccepted() {
        for (url in listOf("http://example.com/script.txt", "file:///script.txt", "https://", "https://user:password@example.com/script.txt")) {
            assertThrows(TeleprompterScriptImportException::class.java) { TeleprompterScriptImport.link(url) }
        }
    }
}
