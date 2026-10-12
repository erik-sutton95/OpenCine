package com.opencapture.opencine.cameracontrols

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import androidx.compose.runtime.Stable
import com.opencapture.opencine.vocabulary.LutCatalog
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

/**
 * One folder of the app-private LUT library: the operator's custom cubes, or a source an app's
 * capabilities add (a vendor download catalog). The name is persisted with a selection.
 */
@JvmInline
value class MonitorLutCategory(val name: String) {
    companion object {
        val CUSTOM: MonitorLutCategory = MonitorLutCategory("CUSTOM")
    }
}

/** A stored cube: its category plus a path-safe `.cube` file name, never a document URI. */
class MonitorLutSelection private constructor(
    val category: MonitorLutCategory,
    val fileName: String,
) {
    override fun equals(other: Any?): Boolean =
        other is MonitorLutSelection && category == other.category && fileName == other.fileName

    override fun hashCode(): Int = 31 * category.hashCode() + fileName.hashCode()

    override fun toString(): String = "MonitorLutSelection(category=${category.name}, fileName=$fileName)"

    companion object {
        /** Null unless the persisted name is a path-safe `.cube` (the shared `LutCatalog` rule). */
        fun of(category: MonitorLutCategory, fileName: String?): MonitorLutSelection? =
            fileName?.takeIf { LutCatalog.isCubeFileName(it) && LutCatalog.isSafeFileName(it) }
                ?.let { MonitorLutSelection(category, it) }
    }
}

/** A listed cube plus the lattice size known once it validated. */
data class MonitorLutEntry(
    val selection: MonitorLutSelection,
    val displayName: String,
    val cubeSize: Int? = null,
)

/** A validated cube packed by the app's renderer adapter (`size³` RGBA8 texels). */
class MonitorPackedLut(val cubeSize: Int, val rgba: ByteArray)

sealed interface MonitorLutImportResult {
    data class Imported(val entry: MonitorLutEntry) : MonitorLutImportResult
    data class Rejected(val message: String) : MonitorLutImportResult
}

/** Why a stored cube cannot be selected or rendered now. */
enum class MonitorLutFailure(val operatorMessage: String) {
    MISSING("This LUT is no longer in the app library. Remove it or choose another look."),
    TOO_LARGE("This LUT exceeds the 16 MB import limit. Remove it or import a smaller .cube."),
    INVALID("This LUT can no longer be validated. Remove it or import the original again."),
    READ_FAILED("This LUT could not be read from the app library. Remove it or import it again."),
}

/**
 * The app-private LUT library (iOS `CustomLUTIndex`): one folder per category, every import
 * validated before a byte is stored, packed render payloads prepared off the draw thread, per-cube
 * failures and a render generation for redraws. [pack] is the app's renderer adapter over the
 * shared Swift `CubeLUT.validatedImport`; null means the bytes are not a supported cube. Names
 * follow the shared custom LUT rule: the operator's file name, replaced on re-import.
 */
@Stable
class MonitorLutLibrary(
    private val directories: Map<MonitorLutCategory, File>,
    private val pack: (ByteArray) -> ByteArray?,
    private val displayName: (String) -> String = LutCatalog::displayName,
) {
    private val lock = Any()
    private val packed = mutableMapOf<MonitorLutSelection, MonitorPackedLut>()
    private val mutableEntries = MutableStateFlow(scan())
    private val mutableFailures = MutableStateFlow<Map<MonitorLutSelection, MonitorLutFailure>>(emptyMap())
    private val mutableRenderGeneration = MutableStateFlow(0L)

    val entries: StateFlow<List<MonitorLutEntry>> = mutableEntries.asStateFlow()
    val failures: StateFlow<Map<MonitorLutSelection, MonitorLutFailure>> = mutableFailures.asStateFlow()
    val renderGeneration: StateFlow<Long> = mutableRenderGeneration.asStateFlow()

    fun contains(selection: MonitorLutSelection): Boolean = fileFor(selection)?.isFile == true

    fun entries(category: MonitorLutCategory): List<MonitorLutEntry> =
        entries.value.filter { it.selection.category == category }

    fun displayName(selection: MonitorLutSelection): String? =
        entries.value.firstOrNull { it.selection == selection }?.displayName

    /** Only a payload [prepare] or an import produced; never file I/O on the draw thread. */
    fun packedCube(selection: MonitorLutSelection): MonitorPackedLut? = synchronized(lock) { packed[selection] }

    /** Reads one document the operator picked (never persisting its URI), then [importCube]. */
    suspend fun importDocument(
        resolver: ContentResolver,
        uri: Uri,
        category: MonitorLutCategory = MonitorLutCategory.CUSTOM,
    ): MonitorLutImportResult = withContext(Dispatchers.IO) {
        val bytes = try {
            readBounded(resolver.openInputStream(uri) ?: throw IOException("No input stream."))
        } catch (_: IOException) {
            return@withContext MonitorLutImportResult.Rejected("The selected document could not be read.")
        } catch (_: SecurityException) {
            return@withContext MonitorLutImportResult.Rejected("The app can no longer read that document.")
        }
        importCube(category, bytes, documentName(resolver, uri) ?: uri.lastPathSegment)
    }

    /** Imports a local cube file (a vendor download or an archive member) into [category]. */
    suspend fun importFile(category: MonitorLutCategory, file: File): MonitorLutImportResult =
        withContext(Dispatchers.IO) {
            val bytes = try { readBounded(FileInputStream(file)) } catch (_: IOException) {
                return@withContext MonitorLutImportResult.Rejected("The .cube file could not be read.")
            }
            importCube(category, bytes, file.name)
        }

    /** Validates and packs [bytes], then copies them atomically into [category] under [sourceName]. */
    suspend fun importCube(category: MonitorLutCategory, bytes: ByteArray, sourceName: String?): MonitorLutImportResult =
        withContext(Dispatchers.IO) {
            if (bytes.size > MAXIMUM_SOURCE_BYTES) {
                return@withContext MonitorLutImportResult.Rejected("This .cube is larger than the 16 MB import limit.")
            }
            val name = sourceName?.let { File(it).name }?.let(LutCatalog::normalizedCubeFileName) ?: FALLBACK_NAME
            val selection = MonitorLutSelection.of(category, name)?.takeIf { fileFor(it) != null }
                ?: return@withContext MonitorLutImportResult.Rejected("This LUT library is not available.")
            val cube = packed(bytes)
                ?: return@withContext MonitorLutImportResult.Rejected("That document is not a supported .cube LUT.")
            try {
                writeAtomically(selection, bytes)
            } catch (_: IOException) {
                return@withContext MonitorLutImportResult.Rejected("The LUT could not be saved in the app library.")
            } catch (_: SecurityException) {
                return@withContext MonitorLutImportResult.Rejected("The LUT could not be saved in the app library.")
            }
            val entry = MonitorLutEntry(selection, displayName(selection.fileName), cube.cubeSize)
            synchronized(lock) {
                packed[selection] = cube
                mutableEntries.value = (mutableEntries.value.filterNot { it.selection == selection } + entry)
                    .sortedBy { it.displayName.lowercase() }
                mutableFailures.value = mutableFailures.value - selection
                mutableRenderGeneration.value += 1
            }
            MonitorLutImportResult.Imported(entry)
        }

    /** Re-validates a stored cube off the UI and render threads; a corrupt file stays listed for removal. */
    suspend fun prepare(selection: MonitorLutSelection): Boolean = withContext(Dispatchers.IO) {
        val file = fileFor(selection)?.takeIf { it.isFile } ?: return@withContext failed(selection, MonitorLutFailure.MISSING)
        if (file.length() > MAXIMUM_SOURCE_BYTES) return@withContext failed(selection, MonitorLutFailure.TOO_LARGE)
        val bytes = try { readBounded(FileInputStream(file)) } catch (_: IOException) {
            return@withContext failed(selection, MonitorLutFailure.READ_FAILED)
        }
        val cube = packed(bytes) ?: return@withContext failed(selection, MonitorLutFailure.INVALID)
        synchronized(lock) {
            packed[selection] = cube
            mutableEntries.value = mutableEntries.value.map { if (it.selection == selection) it.copy(cubeSize = cube.cubeSize) else it }
            mutableFailures.value = mutableFailures.value - selection
            mutableRenderGeneration.value += 1
        }
        true
    }

    /** Deletes only the library's own file and drops its render payload. */
    suspend fun delete(selection: MonitorLutSelection): Boolean = withContext(Dispatchers.IO) {
        val file = fileFor(selection) ?: return@withContext false
        val removed = !file.exists() || file.delete()
        if (removed) synchronized(lock) {
            packed.remove(selection)
            mutableEntries.value = mutableEntries.value.filterNot { it.selection == selection }
            mutableFailures.value = mutableFailures.value - selection
            mutableRenderGeneration.value += 1
        }
        removed
    }

    /** The first same-category cube that still validates after [deleted] goes away. */
    suspend fun firstPreparedReplacement(deleted: MonitorLutSelection): MonitorLutSelection? =
        replacementCandidates(entries.value, deleted).firstOrNull { prepare(it.selection) }?.selection

    private fun packed(bytes: ByteArray): MonitorPackedLut? {
        val rgba = pack(bytes) ?: return null
        val size = Math.round(Math.cbrt(rgba.size / 4.0)).toInt()
        return if (size >= 2 && size * size * size * 4 == rgba.size) MonitorPackedLut(size, rgba) else null
    }

    private fun failed(selection: MonitorLutSelection, failure: MonitorLutFailure): Boolean {
        synchronized(lock) {
            packed.remove(selection)
            mutableFailures.value = mutableFailures.value + (selection to failure)
            mutableRenderGeneration.value += 1
        }
        return false
    }

    private fun scan(): List<MonitorLutEntry> = directories.flatMap { (category, directory) ->
        directory.list().orEmpty().mapNotNull { name ->
            MonitorLutSelection.of(category, name)?.takeIf { File(directory, name).isFile }
                ?.let { MonitorLutEntry(it, displayName(name)) }
        }
    }.sortedBy { it.displayName.lowercase() }

    private fun fileFor(selection: MonitorLutSelection): File? {
        val directory = directories[selection.category] ?: return null
        return File(directory, selection.fileName).takeIf { it.parentFile == directory }
    }

    @Throws(IOException::class)
    private fun writeAtomically(selection: MonitorLutSelection, bytes: ByteArray) {
        val destination = requireNotNull(fileFor(selection))
        val directory = requireNotNull(destination.parentFile)
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Cannot create the LUT library directory.")
        val temporary = File.createTempFile("import-", ".tmp", directory)
        try {
            FileOutputStream(temporary).use { it.write(bytes); it.fd.sync() }
            if (!temporary.renameTo(destination)) throw IOException("Cannot store the LUT.")
        } finally {
            if (temporary.exists()) temporary.delete()
        }
    }

    companion object {
        /** The shared Swift `CubeLUT.maximumImportBytes`. */
        const val MAXIMUM_SOURCE_BYTES: Int = 16 * 1024 * 1024

        private const val FALLBACK_NAME = "Imported.cube"

        /** Same-category successors of a deleted cube, in library order. */
        fun replacementCandidates(entries: List<MonitorLutEntry>, deleted: MonitorLutSelection): List<MonitorLutEntry> =
            entries.filter { it.selection != deleted && it.selection.category == deleted.category }

        /** Reads and closes one stream without ever holding more than the import limit. */
        @Throws(IOException::class)
        fun readBounded(input: InputStream): ByteArray = input.use { stream ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8 * 1024)
            var total = 0
            while (true) {
                val read = stream.read(buffer)
                if (read < 0) break
                total += read
                if (total > MAXIMUM_SOURCE_BYTES) throw IOException("LUT source too large.")
                output.write(buffer, 0, read)
            }
            output.toByteArray()
        }

        private fun documentName(resolver: ContentResolver, uri: Uri): String? = try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                val index = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && it.moveToFirst()) it.getString(index) else null
            }
        } catch (_: SecurityException) {
            null
        }
    }
}
