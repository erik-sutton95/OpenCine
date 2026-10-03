package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID

public enum class MonitorMediaCacheFailure { RETIRED, INVALID_ADDRESS, EMPTY, INVALID_RECEIPT }
public class MonitorMediaCacheException(public val failure: MonitorMediaCacheFailure) : IOException(failure.name)
public data class MonitorMediaCacheAddress(
    public val thumbnail: String,
    public val representations: Map<MediaRepresentationID, String>,
    public val favoriteKey: String,
)
public data class MonitorMediaRecord<P>(
    public val asset: MediaAsset,
    public val payload: P,
    public val address: MonitorMediaCacheAddress,
    public val favorite: Boolean = false,
    public val facts: MonitorMediaFilterFacts = MonitorMediaFilterFacts(),
)
public interface MonitorMediaCatalogCodec<P> {
    public fun decode(bytes: ByteArray): List<MonitorMediaRecord<P>>
    public fun encode(records: List<MonitorMediaRecord<P>>): ByteArray
    /** Capture immutable preservation facts before later encoding/IO can suspend. */
    public fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<P>
}
public sealed interface MonitorMediaOriginalEligibility {
    public data object ExactSize : MonitorMediaOriginalEligibility
    public data class MinimumFraction(public val numerator: Long, public val denominator: Long) : MonitorMediaOriginalEligibility
    public fun accepts(bytes: Long, expected: Long?): Boolean {
        if (bytes <= 0) return false
        if (expected == null || expected <= 0) return true
        return when (this) {
            ExactSize -> bytes == expected
            is MinimumFraction -> {
                if (denominator <= 0 || numerator < 0 || numerator > denominator) false
                else bytes.toBigInteger() >= expected.toBigInteger() * numerator.toBigInteger() / denominator.toBigInteger()
            }
        }
    }
}
public data class MonitorMediaCacheEntry(public val original: File?, public val proxy: File?, public val thumbnail: File?) {
    public val isPlayableOffline: Boolean get() = original != null || proxy != null
}

/** An explicitly shared root lifetime. Clear and destination replacement fence all writer leases. */
public class MonitorMediaCacheDirectory(public val root: File) {
    internal val lock = Any()
    internal var revision: Long = 0
    internal val current = mutableMapOf<String, UUID>()
    internal data class Resource(val stream: FileOutputStream, val temporary: File)
    internal val resources = mutableMapOf<UUID, Resource>()
    public val generation: Long get() = synchronized(lock) { revision }
    public fun file(address: String): File {
        val pieces = address.split('/')
        if (pieces.any { it.isEmpty() || it == "." || it == ".." } || '\\' in address) {
            throw MonitorMediaCacheException(MonitorMediaCacheFailure.INVALID_ADDRESS)
        }
        return File(root, address)
    }
    public fun read(address: String): ByteArray = file(address).readBytes()
    public fun write(bytes: ByteArray, address: String) {
        synchronized(lock) {
            val writer = beginWrite(address)
            try { writer.writeNow(bytes); writer.commit(MediaTransferReceipt(bytes.size.toLong())) }
            finally { writer.abort() }
        }
    }
    public fun existing(address: String): File? = runCatching { file(address).takeIf { it.isFile && it.length() > 0 } }.getOrNull()
    public fun beginWrite(address: String): MonitorMediaCacheWrite = synchronized(lock) {
        val destination = file(address)
        if (destination.parentFile?.let { it.isDirectory || it.mkdirs() } != true) throw IOException("Cannot create cache directory")
        val id = UUID.randomUUID(); val temporary = File(destination.parentFile, "$id.part")
        val stream = FileOutputStream(temporary)
        current[destination.path]?.let { previous -> resources.remove(previous)?.let { runCatching { it.stream.close() }; it.temporary.delete() } }
        current[destination.path] = id; resources[id] = Resource(stream, temporary)
        MonitorMediaCacheWrite(this, id, revision, destination, temporary, stream)
    }
    public suspend fun clear(preserving: List<String>) {
        val pending = synchronized(lock) {
            revision += 1; current.clear()
            resources.values.forEach { runCatching { it.stream.close() } }; resources.clear()
            if (root.exists()) {
                val suffix = "${root.name}-${UUID.randomUUID()}"
                val retired = File(root.parentFile, ".retiring-$suffix")
                val ready = File(root.parentFile, ".clearing-$suffix")
                if (!root.renameTo(retired)) throw IOException("Cannot retire cache directory")
                val moved = mutableListOf<String>()
                try {
                    if (preserving.isNotEmpty() && !root.mkdirs()) throw IOException("Cannot prepare cache directory")
                    preserving.forEach { name ->
                        file(name)
                        val source = File(retired, name)
                        if (source.exists()) {
                            if (!source.renameTo(File(root, name))) throw IOException("Cannot preserve cache metadata")
                            moved += name
                        }
                    }
                    if (!retired.renameTo(ready)) throw IOException("Cannot prepare retired cache")
                } catch (error: Exception) {
                    moved.asReversed().forEach { File(root, it).renameTo(File(retired, it)) }
                    if (root.listFiles()?.isEmpty() == true) root.delete()
                    if (!root.exists()) retired.renameTo(root)
                    throw error
                }
            }
            retiredRoots(includeUnprepared = false)
        }
        withContext(Dispatchers.IO) {
            pending.forEach { if (it.exists() && !it.deleteRecursively()) throw IOException("Cannot delete retired cache") }
        }
    }
    public suspend fun totalByteCount(): Long = withContext(Dispatchers.IO) {
        (listOf(root) + retiredRoots(includeUnprepared = true)).sumOf { directory ->
            directory.walkTopDown().filter { it.isFile }.sumOf { it.length() }
        }
    }
    private fun retiredRoots(includeUnprepared: Boolean): List<File> = root.parentFile?.listFiles().orEmpty().filter {
        it.name.startsWith(".clearing-${root.name}-") || (includeUnprepared && it.name.startsWith(".retiring-${root.name}-"))
    }
}

/** Abort only removes its unique staging path. A retired writer can never commit into a new root. */
public class MonitorMediaCacheWrite internal constructor(
    private val directory: MonitorMediaCacheDirectory, private val id: UUID, private val generation: Long,
    private val destination: File, private val temporary: File, private val stream: FileOutputStream,
) : MediaByteSink, AutoCloseable {
    private var bytes = 0L
    private var finished = false
    private fun check() {
        if (finished || directory.revision != generation || directory.current[destination.path] != id) {
            throw MonitorMediaCacheException(MonitorMediaCacheFailure.RETIRED)
        }
    }
    internal fun writeNow(chunk: ByteArray) = synchronized(directory.lock) { check(); stream.write(chunk); bytes += chunk.size }
    override suspend fun write(chunk: ByteArray) { currentCoroutineContext().ensureActive(); writeNow(chunk) }
    public fun commit(receipt: MediaTransferReceipt): File = synchronized(directory.lock) {
        check()
        if (bytes <= 0) throw MonitorMediaCacheException(MonitorMediaCacheFailure.EMPTY)
        if (bytes != receipt.byteCount) throw MonitorMediaCacheException(MonitorMediaCacheFailure.INVALID_RECEIPT)
        stream.close()
        if (destination.exists() && !destination.delete()) throw IOException("Cannot replace cache file")
        if (!temporary.renameTo(destination)) throw IOException("Cannot commit cache file")
        finished = true; directory.current.remove(destination.path); directory.resources.remove(id)
        destination
    }
    public fun abort(): Unit = synchronized(directory.lock) {
        if (!finished) {
            finished = true; runCatching { stream.close() }; temporary.delete(); directory.resources.remove(id)
            if (directory.current[destination.path] == id) directory.current.remove(destination.path)
        }
    }
    override fun close() { abort() }
}

/** Schema, root lifetime and size policy are supplied by the actual app composition. */
public class MonitorMediaCache<P>(
    public val directory: MonitorMediaCacheDirectory,
    public val codec: MonitorMediaCatalogCodec<P>,
    public val eligibility: MonitorMediaOriginalEligibility,
    private val catalogAddress: String,
    private val preservedMetadata: List<String>,
) {
    public fun load(): List<MonitorMediaRecord<P>> = runCatching { codec.decode(directory.read(catalogAddress)) }.getOrDefault(emptyList())
    public fun save(records: List<MonitorMediaRecord<P>>) { directory.write(codec.encode(records), catalogAddress) }
    public fun entry(record: MonitorMediaRecord<P>): MonitorMediaCacheEntry {
        var original: File? = null; var proxy: File? = null
        record.asset.representations.forEach { representation ->
            val address = record.address.representations[representation.id] ?: return@forEach
            val location = directory.existing(address) ?: return@forEach
            if (representation.role == MediaRepresentationRole.ORIGINAL) {
                if (eligibility.accepts(location.length(), representation.byteCount)) original = location
            } else if (proxy == null) proxy = location
        }
        return MonitorMediaCacheEntry(original, proxy, directory.existing(record.address.thumbnail))
    }
    public suspend fun clear() { directory.clear(preservedMetadata) }
}
