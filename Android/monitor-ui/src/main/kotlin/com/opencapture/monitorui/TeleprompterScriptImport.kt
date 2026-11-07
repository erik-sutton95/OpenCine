package com.opencapture.monitorui

import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Locale

/** A readable local copy, with its original source retained only for explicit refresh. */
public data class TeleprompterScript(public val text: String, public val name: String, public val sourceUrl: String? = null)

/** Import errors never replace an already accepted script. */
public class TeleprompterScriptImportException(message: String) : IllegalArgumentException(message)

/** Portable decoding and script preparation; native adapters own file and network access. */
public object TeleprompterScriptImport {
    /** Maximum source size for paste, files and remote scripts. */
    public const val MAXIMUM_BYTES: Int = 1_048_576

    /** Decodes a bounded UTF-8 TXT/Markdown resource into locally readable text. */
    public fun decode(bytes: ByteArray, name: String, sourceUrl: String? = null, contentType: String? = null): TeleprompterScript {
        requireSize(bytes.size)
        val decoded = try {
            StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
        } catch (_: java.nio.charset.CharacterCodingException) {
            throw TeleprompterScriptImportException("Choose a UTF-8 text or Markdown file.")
        }
        val text = normalized(decoded)
        requireValidText(text)
        val mime = contentType?.substringBefore(';')?.trim()?.lowercase(Locale.ROOT)
        val prefix = text.trimStart().lowercase(Locale.ROOT)
        if (mime in listOf("text/html", "application/xhtml+xml") ||
            (sourceUrl != null && listOf("<!doctype html", "<html", "<head", "<body").any { prefix.startsWith(it) })) {
            throw TeleprompterScriptImportException("This link opens a webpage. Use a direct text or Markdown download link.")
        }
        if (mime != null && mime !in listOf("text/plain", "text/markdown", "text/x-markdown", "application/octet-stream")) {
            throw TeleprompterScriptImportException("Choose a .txt or .md file, or a direct text or Markdown link.")
        }
        val ext = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
        val markdown = ext == "md" || mime in listOf("text/markdown", "text/x-markdown")
        if (!markdown && ext != "txt" && mime != "text/plain") {
            throw TeleprompterScriptImportException("Choose a .txt or .md file, or a direct text or Markdown link.")
        }
        val readable = if (markdown) markdownText(text) else text
        requireValidText(readable)
        return TeleprompterScript(readable, name, sourceUrl)
    }

    /** Accepts text supplied by an explicit paste or edit action. */
    public fun paste(text: String): TeleprompterScript {
        requireSize(text.toByteArray(StandardCharsets.UTF_8).size)
        val readable = normalized(text)
        requireValidText(readable)
        return TeleprompterScript(readable, "Pasted script")
    }

    /** Validates public HTTPS sources without authentication or webpage extraction. */
    public fun link(value: String): String {
        val trimmed = value.trim()
        val uri = try { URI(trimmed) } catch (_: java.net.URISyntaxException) { null }
        if (uri == null || !uri.scheme.equals("https", ignoreCase = true) || uri.host.isNullOrEmpty() || uri.userInfo != null) {
            throw TeleprompterScriptImportException("Enter a public HTTPS link to a text or Markdown script.")
        }
        return trimmed
    }

    private fun requireSize(size: Int) {
        if (size > MAXIMUM_BYTES) throw TeleprompterScriptImportException("Choose a script smaller than 1 MiB.")
    }

    private fun requireValidText(text: String) {
        if ('\u0000' in text) throw TeleprompterScriptImportException("Choose a UTF-8 text or Markdown file.")
        if (text.isBlank()) throw TeleprompterScriptImportException("The script does not contain any readable text.")
    }

    private fun normalized(text: String): String = text.removePrefix("\uFEFF").replace("\r\n", "\n").replace('\r', '\n')

    private fun markdownText(text: String): String {
        var fence: Char? = null
        return text.split('\n').mapNotNull { line ->
            val trimmed = line.trim()
            val current = fence
            if (current != null) {
                if (trimmed.startsWith(current.toString().repeat(3))) { fence = null; null } else line
            } else if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
                fence = trimmed.first(); null
            } else if (Regex("^(?:=+|-{3,}|\\*{3,}|_{3,})$").matches(trimmed)) {
                null
            } else {
                var readable = line.replace(Regex("^\\s{0,3}#{1,6}\\s+(.+?)(?:\\s+#+)?\\s*$"), "$1")
                readable = readable.replace(Regex("^\\s{0,3}(?:>\\s?)+"), "")
                readable = readable.replace(Regex("^\\s*[-+*]\\s+(?:\\[[ xX]\\]\\s+)?"), "• ")
                readable = readable.replace(Regex("!?\\[([^\\]]*)\\]\\([^\\n)]*\\)"), "$1")
                if ('`' !in readable) {
                    readable = readable.replace(Regex("</?[A-Za-z][A-Za-z0-9]*(?:\\s[^<>]*)?/?>"), "")
                }
                readable = readable.replace(Regex("(?<!\\\\)(\\*\\*|__)(?=\\S)(.+?)\\1"), "$2")
                readable = readable.replace(Regex("(?<![\\\\\\w])([*_])(?=\\S)(.+?)(?<=\\S)\\1(?!\\w)"), "$2")
                readable = readable.replace(Regex("(`+)(.+?)\\1"), "$2")
                readable.replace(Regex("\\\\([\\\\`*_{}\\[\\]()#+.!>\\-])"), "$1")
            }
        }.joinToString("\n")
    }
}
