package com.opencapture.opencine.appkit.sentry

import io.sentry.ISerializer
import io.sentry.SentryEnvelope
import java.io.File
import java.io.FileNotFoundException

/**
 * PA-12 (OPENPOCKETCINE-ANDROID-12). Reads the SDK's envelope disk cache one file at a time.
 *
 * The SDK's `EnvelopeCache` iterator reads every `*.envelope` file in one pass and catches only
 * IO errors, so the IllegalArgumentException its reader throws on a malformed header failed the
 * whole read on every drain and stranded every healthy report behind one bad file. It also
 * returns envelopes without their files, and `discard` finds a file only through the name map of
 * the process that stored it, so a report reloaded after a restart was never deleted once
 * delivered and every later drain sent it again.
 *
 * Here an unreadable file is skipped, and removed once it is older than [SETTLE_MS] (a younger
 * one may still be being written by the SDK). Each readable envelope keeps its file.
 */
internal object CachedEnvelopeFiles {
    const val SETTLE_MS = 60_000L
    private const val SUFFIX = ".envelope"

    class Read(val entries: List<Pair<File, SentryEnvelope>>, val removed: Int)

    /** Names of the envelope files in [directory] now. */
    fun names(directory: File?): Set<String> =
        directory?.list { _, name -> name.endsWith(SUFFIX) }?.toSet().orEmpty()

    /** Up to [limit] readable envelopes, oldest first, and how many unreadable files were removed. */
    fun read(directory: File?, serializer: ISerializer, nowMs: Long, limit: Int): Read {
        val files = directory?.listFiles { _, name -> name.endsWith(SUFFIX) } ?: return Read(emptyList(), 0)
        val entries = ArrayList<Pair<File, SentryEnvelope>>()
        var removed = 0
        for (file in files.sortedBy { it.lastModified() }) {
            if (entries.size >= limit) break
            val envelope =
                try {
                    file.inputStream().buffered().use { serializer.deserializeEnvelope(it) }
                } catch (_: FileNotFoundException) {
                    continue // Delivered and discarded meanwhile.
                } catch (_: Exception) {
                    null
                }
            if (envelope != null) {
                entries += file to envelope
            } else if (nowMs - file.lastModified() >= SETTLE_MS && file.delete()) {
                removed++
            }
        }
        return Read(entries, removed)
    }
}
