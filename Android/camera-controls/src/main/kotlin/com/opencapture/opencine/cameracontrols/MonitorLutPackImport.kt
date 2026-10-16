package com.opencapture.opencine.cameracontrols

import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** What importing a downloaded LUT pack (a zip, or a lone `.cube`) into one library category did. */
public data class MonitorLutPackImportResult(
    public val importedCount: Int,
    public val foundCubeEntries: Int = importedCount,
    public val rejectedCubeEntries: Int = 0,
    /** The download is neither a `.cube` nor a zip archive. */
    public val notAnArchive: Boolean = false,
    /** The archive could not be walked; the reader's own words, for the host's copy. */
    public val archiveError: String? = null,
)

/**
 * Imports a downloaded pack into [category]: every `.cube` entry (nested folders allowed, the
 * `__MACOSX` shadow skipped) up to [MONITOR_LUT_ARCHIVE_MAX_CUBE_FILES] files of
 * [MONITOR_LUT_ARCHIVE_MAX_CUBE_BYTES] each, the Swift `CustomLUTStore.importArchive` policy.
 * Each cube is staged under [stagingRoot] (app-private, no backup) and validated by the library's
 * own import gate. Never uses `java.util.zip.ZipFile` or `ZipInputStream`: see [MonitorLutArchive].
 */
public suspend fun MonitorLutLibrary.importPack(
    category: MonitorLutCategory,
    file: File,
    stagingRoot: File,
): MonitorLutPackImportResult = withContext(Dispatchers.IO) {
    suspend fun importOne(cube: File): Boolean =
        importFile(category, cube) is MonitorLutImportResult.Imported
    if (file.name.endsWith(".cube", ignoreCase = true)) {
        val ok = importOne(file)
        return@withContext MonitorLutPackImportResult(if (ok) 1 else 0, 1, if (ok) 0 else 1)
    }
    if (!file.looksLikeZipArchive()) return@withContext MonitorLutPackImportResult(0, notAnArchive = true)
    val cubes = try {
        MonitorLutArchive.extractCubes(file)
    } catch (error: Exception) {
        return@withContext MonitorLutPackImportResult(0, archiveError = error.message ?: "unknown error")
    }
    if (cubes.isEmpty()) return@withContext MonitorLutPackImportResult(0, foundCubeEntries = 0)
    val staging = File(stagingRoot, "run-${System.nanoTime()}")
    staging.mkdirs()
    try {
        var imported = 0
        var rejected = 0
        for (cube in cubes) {
            val staged = File(staging, sanitizeLutCubeFileName(cube.fileName))
            try {
                staged.writeBytes(cube.bytes)
                if (importOne(staged)) imported += 1 else rejected += 1
            } finally {
                staged.delete()
            }
        }
        MonitorLutPackImportResult(imported, cubes.size, rejected)
    } finally {
        staging.deleteRecursively()
    }
}

/** True when the file starts with a ZIP signature (`PK\x03\x04`, `PK\x05\x06` or `PK\x07\x08`). */
public fun File.looksLikeZipArchive(): Boolean {
    if (!isFile || length() < 4L) return false
    return inputStream().use { stream ->
        val sig = ByteArray(4)
        if (stream.read(sig) < 4) return@use false
        sig[0] == 'P'.code.toByte() && sig[1] == 'K'.code.toByte() &&
            ((sig[2] == 3.toByte() && sig[3] == 4.toByte()) ||
                (sig[2] == 5.toByte() && sig[3] == 6.toByte()) ||
                (sig[2] == 7.toByte() && sig[3] == 8.toByte()))
    }
}

/** Keeps only a safe basename (letters, digits, `.`, `-`, `_`) ending in `.cube`, at most 180 characters. */
public fun sanitizeLutCubeFileName(raw: String): String {
    val base = raw.substringAfterLast('/').substringAfterLast('\\').ifBlank { "lut.cube" }
    val cleaned = buildString(base.length) {
        for (ch in base) append(if (ch.isLetterOrDigit() || ch == '.' || ch == '-' || ch == '_') ch else '_')
    }
    val withExt = if (cleaned.endsWith(".cube", ignoreCase = true)) cleaned else "$cleaned.cube"
    return withExt.take(180).ifBlank { "lut.cube" }
}
