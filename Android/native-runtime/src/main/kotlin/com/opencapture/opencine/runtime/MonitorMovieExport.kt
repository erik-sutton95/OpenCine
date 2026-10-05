package com.opencapture.opencine.runtime

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** One approved display-encoded SDR cube, in the monitor's packed RGBA texture order. */
class MonitorMovieExportLut(
    val displayName: String,
    val cubeSize: Int,
    val packedRgba: ByteArray,
) {
    init {
        require(cubeSize in 2..64 && packedRgba.size == cubeSize * cubeSize * cubeSize * 4) {
            "The selected LUT payload is invalid."
        }
    }

    override fun toString(): String = "MonitorMovieExportLut(name=$displayName, pixels=redacted)"

    /** Converts `(x=b*n+r,y=g)` RGBA8 texture order to codec `cube[r][g][b]`. */
    fun toArgbCube(): Array<Array<IntArray>> =
        Array(cubeSize) { red ->
            Array(cubeSize) { green ->
                IntArray(cubeSize) { blue ->
                    val offset = ((green * cubeSize + blue) * cubeSize + red) * 4
                    val r = packedRgba[offset].toInt() and 0xFF
                    val g = packedRgba[offset + 1].toInt() and 0xFF
                    val b = packedRgba[offset + 2].toInt() and 0xFF
                    val a = packedRgba[offset + 3].toInt() and 0xFF
                    (a shl 24) or (r shl 16) or (g shl 8) or b
                }
            }
        }
}

enum class MonitorMovieExportContainer(val label: String, val extension: String, val mimeType: String) {
    MOV("MOV", "mov", "video/quicktime"),
    MP4("MP4", "mp4", "video/mp4"),
}

/** Coherent export failures; the host supplies its existing operator wording and error type. */
enum class MonitorMovieExportFailure {
    UNSUPPORTED_BAKE,
    APPROVED_LUT_UNAVAILABLE,
    INCOMPLETE_EXPORT,
    INVALID_MOV_FILE,
    INCOMPLETE_MOV_HEADER,
    UNSUPPORTED_MOV_HEADER,
    CODEC_FAILED,
    CODEC_STALLED,
    INCOMPLETE_CLEANUP,
    TEMPORARY_CLEANUP,
}

fun interface MonitorMovieExportErrorFactory {
    fun make(reason: MonitorMovieExportFailure, originalFilename: String?): Throwable
}

interface MonitorLutMovieExporter {
    suspend fun export(source: Path, target: Path, lut: MonitorMovieExportLut, onProgress: suspend (Double) -> Unit)
}

/** Native SDK construction stays in the host; each operation gets its own codec instance. */
fun interface MonitorMovieCodecFactory {
    fun create(source: Path, target: Path, lut: MonitorMovieExportLut, completion: MonitorMovieCodecCompletion): MonitorMovieCodec
}

interface MonitorMovieCodecCompletion {
    fun completed()
    fun failed()
}

interface MonitorMovieCodec {
    fun start()
    /** Absent progress is unknown; known zero remains zero. */
    fun progressPercent(): Int?
    fun cancel()
}

/** Monotonic no-progress deadline for device codec/driver stalls. */
class MonitorMovieExportProgressWatchdog(
    stallTimeoutMillis: Long,
    private val nanoClock: () -> Long = System::nanoTime,
) {
    private val stallTimeoutNanos: Long
    private var lastProgress = -1
    private var lastAdvanceNanos: Long

    init {
        require(stallTimeoutMillis in 1..Long.MAX_VALUE / NANOS_PER_MILLISECOND) {
            "Export stall timeout must be positive and bounded."
        }
        stallTimeoutNanos = stallTimeoutMillis * NANOS_PER_MILLISECOND
        lastAdvanceNanos = nanoClock()
    }

    fun recordProgress(progress: Int) {
        val bounded = progress.coerceIn(0, 100)
        if (bounded > lastProgress) {
            lastProgress = bounded
            lastAdvanceNanos = nanoClock()
        }
    }

    fun hasStalled(): Boolean = nanoClock() - lastAdvanceNanos >= stallTimeoutNanos

    private companion object {
        const val NANOS_PER_MILLISECOND = 1_000_000L
    }
}

/** Owns native completion, progress polling, stall and cancellation for an actual movie export. */
class MonitorNativeMovieExporter(
    private val factory: MonitorMovieCodecFactory,
    private val errors: MonitorMovieExportErrorFactory,
    private val mainDispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
    private val progressPollMillis: Long = 180L,
    private val stallTimeoutMillis: Long = 180_000L,
    private val nanoClock: () -> Long = System::nanoTime,
) : MonitorLutMovieExporter {
    init {
        require(progressPollMillis > 0)
        require(stallTimeoutMillis in 1..Long.MAX_VALUE / 1_000_000L)
    }

    override suspend fun export(
        source: Path,
        target: Path,
        lut: MonitorMovieExportLut,
        onProgress: suspend (Double) -> Unit,
    ) = withContext(mainDispatcher) {
        Files.deleteIfExists(target)
        val completion = CompletableDeferred<Unit>()
        val codec = factory.create(source, target, lut, object : MonitorMovieCodecCompletion {
            override fun completed() { completion.complete(Unit) }
            override fun failed() { completion.completeExceptionally(errors.make(MonitorMovieExportFailure.CODEC_FAILED, null)) }
        })
        coroutineScope {
            codec.start()
            val watchdog = MonitorMovieExportProgressWatchdog(stallTimeoutMillis, nanoClock)
            val progressJob = launch {
                while (isActive && !completion.isCompleted) {
                    codec.progressPercent()?.let { progress ->
                        watchdog.recordProgress(progress)
                        onProgress((progress / 100.0).coerceIn(0.0, 1.0))
                    }
                    if (watchdog.hasStalled()) {
                        codec.cancel()
                        completion.completeExceptionally(errors.make(MonitorMovieExportFailure.CODEC_STALLED, null))
                    }
                    delay(progressPollMillis)
                }
            }
            try {
                completion.await()
                onProgress(1.0)
            } finally {
                progressJob.cancel()
                if (!completion.isCompleted) codec.cancel()
            }
        }
    }
}

class MonitorMovieExportInput(val file: Path, val displayName: String, val mimeType: String, val byteCount: Long, val supportsLutBake: Boolean)

class MonitorPreparedMovieExport(
    val file: Path,
    val displayName: String,
    val mimeType: String,
    val byteCount: Long,
    val appliedLutName: String?,
    val transientExport: Path?,
)

/** Owns the transient artifact, file finalization, metadata and cleanup for approved media. */
class MonitorMovieExportPreparer(
    private val exportRoot: Path,
    private val exporter: MonitorLutMovieExporter,
    private val errors: MonitorMovieExportErrorFactory,
    private val ownedFilenamePrefix: String = "movie",
    private val fallbackFilename: String = "Movie",
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val deleteExport: (Path) -> Boolean = Files::deleteIfExists,
) {
    init { require(ownedFilenamePrefix.matches(Regex("[A-Za-z0-9_]+"))) }

    suspend fun prepare(
        input: MonitorMovieExportInput,
        bakeLut: Boolean,
        container: MonitorMovieExportContainer,
        approvedLut: suspend () -> MonitorMovieExportLut?,
        onProgress: suspend (Double) -> Unit,
    ): MonitorPreparedMovieExport {
        if (!bakeLut) return MonitorPreparedMovieExport(input.file, input.displayName, input.mimeType, input.byteCount, null, null)
        if (!input.supportsLutBake) throw errors.make(MonitorMovieExportFailure.UNSUPPORTED_BAKE, input.displayName)
        val lut = approvedLut() ?: throw errors.make(MonitorMovieExportFailure.APPROVED_LUT_UNAVAILABLE, null)
        withContext(ioDispatcher) {
            Files.createDirectories(exportRoot)
            pruneOwnedMovieExports(exportRoot, ownedFilenamePrefix = ownedFilenamePrefix)
        }
        val target = exportRoot.resolve("$ownedFilenamePrefix-${UUID.randomUUID()}.${container.extension}")
        try {
            exporter.export(input.file, target, lut, onProgress)
            val byteCount = withContext(ioDispatcher) {
                finalizeMovieExportContainer(target, container, errors)
                if (!Files.isRegularFile(target) || Files.size(target) <= 0) throw errors.make(MonitorMovieExportFailure.INCOMPLETE_EXPORT, null)
                MonitorMovieTimecode.copyTimecodeTrack(input.file, target)
                Files.size(target)
            }
            val name = input.displayName.substringBeforeLast('.', missingDelimiterValue = input.displayName).ifBlank { fallbackFilename } + ".${container.extension}"
            return MonitorPreparedMovieExport(target, name, container.mimeType, byteCount, lut.displayName, target)
        } catch (error: Throwable) {
            val cleanupFailure = withContext(NonCancellable + ioDispatcher) {
                try {
                    val removed = deleteExport(target)
                    if (!removed && Files.exists(target, LinkOption.NOFOLLOW_LINKS)) errors.make(MonitorMovieExportFailure.INCOMPLETE_CLEANUP, null) else null
                } catch (cleanupError: Throwable) { cleanupError }
            }
            cleanupFailure?.let(error::addSuppressed)
            throw error
        }
    }

    suspend fun release(prepared: MonitorPreparedMovieExport) {
        withContext(NonCancellable + ioDispatcher) {
            prepared.transientExport?.let { path ->
                val removed = try { deleteExport(path) } catch (_: Exception) { false }
                if (!removed && Files.exists(path, LinkOption.NOFOLLOW_LINKS)) throw errors.make(MonitorMovieExportFailure.TEMPORARY_CLEANUP, null)
            }
        }
    }
}

/** The completed ISO-BMFF H264/AAC output can use QuickTime brands without changing sample data. */
fun finalizeMovieExportContainer(target: Path, container: MonitorMovieExportContainer, errors: MonitorMovieExportErrorFactory) {
    if (container == MonitorMovieExportContainer.MP4) return
    if (!Files.isRegularFile(target, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(target)) throw errors.make(MonitorMovieExportFailure.INVALID_MOV_FILE, null)
    FileChannel.open(target, StandardOpenOption.READ, StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS).use { channel ->
        val header = ByteBuffer.allocate(QUICKTIME_FTYP_HEADER_BYTES).order(ByteOrder.BIG_ENDIAN)
        while (header.hasRemaining()) {
            if (channel.read(header) <= 0) throw errors.make(MonitorMovieExportFailure.INCOMPLETE_MOV_HEADER, null)
        }
        header.flip()
        val boxSize = header.int.toLong() and 0xFFFF_FFFFL
        val boxType = ByteArray(4).also(header::get)
        if (!boxType.contentEquals(FTYP_BOX_TYPE) || boxSize < QUICKTIME_FTYP_HEADER_BYTES || boxSize > channel.size()) throw errors.make(MonitorMovieExportFailure.UNSUPPORTED_MOV_HEADER, null)
        writeFully(channel, QUICKTIME_MAJOR_BRAND_OFFSET, QUICKTIME_BRAND)
        writeFully(channel, QUICKTIME_COMPATIBLE_BRAND_OFFSET, QUICKTIME_BRAND)
        channel.force(true)
    }
}

private fun writeFully(channel: FileChannel, offset: Long, bytes: ByteArray) {
    channel.position(offset)
    val buffer = ByteBuffer.wrap(bytes)
    while (buffer.hasRemaining()) channel.write(buffer)
}

private val FTYP_BOX_TYPE = byteArrayOf(0x66, 0x74, 0x79, 0x70)
private val QUICKTIME_BRAND = byteArrayOf(0x71, 0x74, 0x20, 0x20)
private const val QUICKTIME_FTYP_HEADER_BYTES = 20
private const val QUICKTIME_MAJOR_BRAND_OFFSET = 8L
private const val QUICKTIME_COMPATIBLE_BRAND_OFFSET = 16L

/** Prunes only owned UUID exports, preserving protected files and all unrelated cache entries. */
fun pruneOwnedMovieExports(
    root: Path,
    protected: Set<Path> = emptySet(),
    nowEpochMillis: Long = System.currentTimeMillis(),
    maximumAgeMillis: Long = 24L * 60L * 60L * 1_000L,
    maximumBytes: Long = 2L * 1_024L * 1_024L * 1_024L,
    ownedFilenamePrefix: String = "movie",
) {
    require(maximumAgeMillis >= 0 && maximumBytes >= 0)
    require(ownedFilenamePrefix.matches(Regex("[A-Za-z0-9_]+")))
    if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS)) return
    val ownedFilename = Regex(Regex.escape(ownedFilenamePrefix) + "-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\.(mov|mp4)")
    val protectedPaths = protected.map { it.toAbsolutePath().normalize() }.toSet()
    val candidates = Files.list(root).use { paths ->
        paths.iterator().asSequence()
            .filter { path -> path.fileName.toString().matches(ownedFilename) && Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) && !Files.isSymbolicLink(path) }
            .map { path -> OwnedMovieExport(path, Files.getLastModifiedTime(path).toMillis(), Files.size(path)) }
            .sortedBy(OwnedMovieExport::modifiedAt).toList()
    }
    val surviving = mutableListOf<OwnedMovieExport>()
    candidates.forEach { export ->
        val normalized = export.path.toAbsolutePath().normalize()
        val expired = nowEpochMillis - export.modifiedAt > maximumAgeMillis
        if (normalized !in protectedPaths && expired) Files.deleteIfExists(export.path) else surviving += export
    }
    var totalBytes = surviving.sumOf(OwnedMovieExport::sizeBytes)
    surviving.forEach { export ->
        if (totalBytes <= maximumBytes) return@forEach
        val normalized = export.path.toAbsolutePath().normalize()
        if (normalized !in protectedPaths && Files.deleteIfExists(export.path)) totalBytes -= export.sizeBytes
    }
}

private data class OwnedMovieExport(val path: Path, val modifiedAt: Long, val sizeBytes: Long)
