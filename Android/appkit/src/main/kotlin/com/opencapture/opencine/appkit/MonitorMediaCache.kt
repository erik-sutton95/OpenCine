package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.io.FileOutputStream
import java.io.IOException
import java.util.UUID
import java.util.concurrent.locks.ReentrantLock
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.CoroutineContext

public enum class MonitorMediaCacheFailure { RETIRED, INVALID_ADDRESS, EMPTY, INVALID_RECEIPT }
public class MonitorMediaCacheException(public val failure: MonitorMediaCacheFailure) : IOException(failure.name)
/** Confirmed selective removals and every selected file that remains retryable. */
public data class MonitorMediaCacheRemoval(public val removedBytes: Long, public val remainingFiles: List<String>)
public data class MonitorMediaCacheAddress(
    public val thumbnail: String?,
    public val representations: Map<MediaRepresentationID, String>,
    public val favoriteKey: String,
    /** Ordered read alternatives; transfer destination remains the canonical address. */
    public val readAlternatives: Map<MediaRepresentationID, List<String>> = emptyMap(),
)
public enum class MonitorMediaFavoriteAuthority { LEGACY_COMBINED, SOURCE, LOCAL_OVERLAY }
public data class MonitorMediaRecord<P>(
    public val asset: MediaAsset,
    public val payload: P,
    public val address: MonitorMediaCacheAddress,
    public val favorite: Boolean = false,
    public val facts: MonitorMediaFilterFacts = MonitorMediaFilterFacts(),
    public val favoriteAuthority: MonitorMediaFavoriteAuthority = MonitorMediaFavoriteAuthority.LEGACY_COMBINED,
    public val sourceFavorite: Boolean? = null,
)
public interface MonitorMediaCatalogByteStore {
    public val namespace: String
    public val generation: Long
    public fun read(): ByteArray?
    public fun write(bytes: ByteArray, ifCurrent: () -> Boolean)
    /** Null means unchanged; no byte write or registry update. Override under the original lock. */
    public fun update(ifCurrent: () -> Boolean, encode: (ByteArray?) -> ByteArray?) {
        if (!ifCurrent()) throw MonitorMediaCacheException(MonitorMediaCacheFailure.RETIRED)
        val current = read()?.copyOf()
        if (!ifCurrent()) throw MonitorMediaCacheException(MonitorMediaCacheFailure.RETIRED)
        val bytes = encode(current) ?: return
        if (!ifCurrent()) throw MonitorMediaCacheException(MonitorMediaCacheFailure.RETIRED)
        write(bytes, ifCurrent)
    }
}
public interface MonitorMediaCatalogCodec<P> {
    public fun decode(bytes: ByteArray): List<MonitorMediaRecord<P>>
    public fun encode(records: List<MonitorMediaRecord<P>>): ByteArray
    /** Pure preparation against authoritative bytes under the store's original update lock. */
    public fun encodeForPersistence(records: List<MonitorMediaRecord<P>>, currentBytes: ByteArray?): ByteArray? = encode(records)
    /** Capture immutable preservation facts before later encoding/IO can suspend. */
    public fun capture(asset: MediaAsset, binding: MediaBrowseBinding): MonitorMediaRecord<P>
    /** Capture old removals/new values/local amendments under the producing binding before IO. */
    public fun captureCatalog(delta: MediaCatalogDelta, binding: MediaBrowseBinding,
        existing: List<MonitorMediaRecord<P>>): MonitorMediaCatalogCapture<P> =
        MonitorMediaCatalogCapture(delta.reset, delta.upserts.map { capture(it, binding) }, delta.removed)
    /** Optional exact cache IO over immutable captured rows; never query source here. */
    public suspend fun prepareCatalog(capture: MonitorMediaCatalogCapture<P>, binding: MediaBrowseBinding,
        existing: List<MonitorMediaRecord<P>>): MonitorMediaCatalogCapture<P> = capture

}
public data class MonitorMediaCatalogCapture<P>(
    public val resetLibrary: Boolean,
    public val upserts: List<MonitorMediaRecord<P>>,
    public val removed: List<MediaAssetID> = emptyList(),
    public val amendments: List<MonitorMediaRecord<P>> = emptyList(),
    public val order: List<MediaAssetID>? = null,
    public val sourceFavoriteKeys: Set<String>? = null,
)
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
/** One caller-owned declared root; gallery and settings share each namespace's write generation. */
public class MonitorMediaCacheRoot(public val root: File,
    private val accountLegacyUnpreparedRoots: Boolean = false,
) {
    private val directories = mutableMapOf<String, MonitorMediaCacheDirectory>()
    @Synchronized public fun directory(namespace: String): MonitorMediaCacheDirectory {
        if (namespace.isEmpty() || namespace == "." || namespace == ".." || '/' in namespace || '\\' in namespace) {
            throw MonitorMediaCacheException(MonitorMediaCacheFailure.INVALID_ADDRESS)
        }
        return directories.getOrPut(namespace) {
            MonitorMediaCacheDirectory(File(root, namespace), accountLegacyUnpreparedRoots)
        }
    }
    /** Every live or valid retired camera namespace once, in stable order, for Settings count/Clear. */
    public fun cachedDirectories(): List<MonitorMediaCacheDirectory> =
        MonitorMediaCacheNamespaces.names(root).map(::directory)

}

public class MonitorMediaCacheDirectory(public val root: File,
    private val accountLegacyUnpreparedRoots: Boolean = false,
) {
    internal val lock = Any()
    internal var revision: Long = 0
    internal val current = mutableMapOf<String, UUID>()
    internal class Resource(val stream: FileOutputStream, val temporary: File) {
        private val io = ReentrantLock()
        private val closing = Any()
        private var closeRequested = false
        // Owned by io, including a deferred close.
        private var closed = false
        fun <T> withIO(body: () -> T): T {
            io.lock()
            try { return body() }
            finally {
                val shouldClose = synchronized(closing) {
                    if (closeRequested) true else {
                        // Release under closing so a later request cannot miss both owners.
                        io.unlock(); false
                    }
                }
                if (shouldClose) {
                    try { runCatching { close() } } finally { io.unlock() }
                }
            }
        }
        fun close() {
            if (!closed) { stream.close(); closed = true }
        }
        fun requestClose() {
            synchronized(closing) { closeRequested = true }
            Dispatchers.IO.dispatch(EmptyCoroutineContext, Runnable {
                // A busy owner observes closeRequested on release. Never wait on an
                // IO worker or close concurrently with FileOutputStream.write.
                if (io.tryLock()) {
                    try { runCatching { close() } } finally { io.unlock() }
                }
            })
        }
    }
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
        val writer = beginWrite(address)
        try { writer.writeNow(bytes); writer.commit(MediaTransferReceipt(bytes.size.toLong())) }
        finally { writer.abort() }
    }
    public fun existing(address: String): File? = runCatching { file(address).takeIf { it.isFile && it.length() > 0 } }.getOrNull()
    public fun beginWrite(address: String): MonitorMediaCacheWrite =
        beginWrite(address) { stream, bytes -> stream.write(bytes) }
    // Internal real-I/O seam. Public callers keep the original FileOutputStream operation.
    internal fun beginWrite(address: String,
        writeOperation: (FileOutputStream, ByteArray) -> Unit,
    ): MonitorMediaCacheWrite {
        var retired: Resource? = null
        try {
            return synchronized(lock) {
                val destination = file(address)
                if (destination.parentFile?.let { it.isDirectory || it.mkdirs() } != true) throw IOException("Cannot create cache directory")
                val id = UUID.randomUUID(); val temporary = File(destination.parentFile, "$id.part")
                val stream = FileOutputStream(temporary)
                current[destination.path]?.let { previous ->
                    resources.remove(previous)?.let { retired = it; it.temporary.delete() }
                }
                val resource = Resource(stream, temporary)
                current[destination.path] = id; resources[id] = resource
                MonitorMediaCacheWrite(this, id, revision, destination, resource, writeOperation)
            }
        } finally { retired?.requestClose() }
    }
    /** Fence old writers/catalog captures while retaining files owned by resumable transfers. */
    public fun retireWrites() {
        val retired = synchronized(lock) {
            revision += 1; current.clear()
            val values = resources.values.toList()
            values.forEach { it.temporary.delete() }
            resources.clear()
            values
        }
        retired.forEach { it.requestClose() }
    }
    public suspend fun clear(preserving: List<String>) {
        var retired: List<Resource> = emptyList()
        val pending = try { synchronized(lock) {
            revision += 1; current.clear()
            retired = resources.values.toList(); resources.clear()
            // A preserved parent must not carry an active old stream into the new root.
            retired.forEach {
                if (it.temporary.exists() && !it.temporary.delete()) throw IOException("Cannot retire active cache staging file")
            }
            if (MonitorMediaCacheNamespaces.isDirectory(root)) {
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
        } } finally { retired.forEach { it.requestClose() } }
        withContext(Dispatchers.IO) {
            pending.forEach { directory ->
                try {
                    // Files.walk does not follow links, including a nested link outside the cache.
                    Files.walk(directory.toPath()).use { paths ->
                        paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
                    }
                } catch (_: NoSuchFileException) { /* Another Clear already removed this retired root. */ }
            }
        }
    }
    /** Per-clip shot color codes kept beside this directory's catalog; one store per directory. */
    public val shotColors: MonitorMediaShotColorStore by lazy { MonitorMediaShotColorStore(this) }
    public suspend fun totalByteCount(): Long = withContext(Dispatchers.IO) {
        (listOf(root) + retiredRoots(includeUnprepared = true)).sumOf { directory ->
            if (!MonitorMediaCacheNamespaces.isDirectory(directory)) 0L else
                Files.walk(directory.toPath()).use { paths ->
                    paths.filter { Files.isRegularFile(it, LinkOption.NOFOLLOW_LINKS) }
                        .mapToLong { Files.size(it) }.sum()
                }
        }
    }
    /** Missing declared files count as zero; failed observations throw and retain an unknown readout. */
    public suspend fun selectedByteCount(addresses: List<String>): Long = withContext(Dispatchers.IO) {
        currentCoroutineContext().ensureActive()
        selectedFiles(addresses).sumOf { address ->
            currentCoroutineContext().ensureActive()
            selectedFileSize(address) ?: 0L
        }
    }
    /**
     * Retires writers and removes declared files and real descendants of declared directories.
     * Traversal/stat stays outside arbitration; each mutation checks its captured destination
     * authority. Successors and unnamed staging survive; cancellation/deadlines belong to the caller.
     */
    public suspend fun removeFiles(addresses: List<String>): MonitorMediaCacheRemoval = withContext(Dispatchers.IO) {
        val context = currentCoroutineContext()
        context.ensureActive()
        val selected = selectedFiles(addresses).associateWith { selectedRemovalFiles(it, context) }
        val reservations = selectedFiles(selected.values.flatten()).associate { file(it).path to UUID.randomUUID() }
        val (captured, retired) = synchronized(lock) {
            context.ensureActive()
            revision += 1; current.clear()
            val values = resources.values.toList(); resources.clear()
            current.putAll(reservations)
            revision to values
        }
        // A selective clear cannot infer that unnamed staging bytes are disposable cache.
        retired.forEach { it.requestClose() }
        var bytes = 0L
        val remaining = mutableListOf<String>()
        try {
            for ((declared, paths) in selected) {
                var failed = false
                for (address in paths) {
                    context.ensureActive()
                    try {
                        val info = selectedAttributes(address) ?: continue
                        val destination = file(address)
                        synchronized(lock) {
                            context.ensureActive()
                            if (revision != captured) throw MonitorMediaCacheException(MonitorMediaCacheFailure.RETIRED)
                            if (current[destination.path] != reservations[destination.path]) return@synchronized
                            // deleteIfExists never recursively deletes a directory populated by a successor.
                            if (Files.deleteIfExists(destination.toPath()) && info.isRegularFile) bytes += info.size()
                            current.remove(destination.path)
                        }
                    } catch (_: NoSuchFileException) {
                        // Another owner already removed this captured file.
                    } catch (error: MonitorMediaCacheException) {
                        if (error.failure == MonitorMediaCacheFailure.RETIRED) throw error
                        failed = true
                    } catch (_: IOException) { failed = true }
                }
                if (failed) remaining += declared
            }
        } finally {
            synchronized(lock) {
                reservations.forEach { (path, token) -> if (current[path] == token) current.remove(path) }
            }
        }
        MonitorMediaCacheRemoval(bytes, remaining.toList())
    }
    private fun selectedFiles(addresses: List<String>): List<String> = addresses.distinct().sorted().also {
        it.forEach(::file)
    }
    private fun selectedFileSize(address: String): Long? {
        val info = selectedAttributes(address) ?: return null
        if (!info.isRegularFile) throw MonitorMediaCacheException(MonitorMediaCacheFailure.INVALID_ADDRESS)
        return info.size()
    }
    private fun selectedRemovalFiles(address: String, context: CoroutineContext): List<String> {
        context.ensureActive()
        return try {
            val info = selectedAttributes(address)
            if (info?.isDirectory != true) listOf(address) else {
                val children = Files.newDirectoryStream(file(address).toPath()).use { entries ->
                    entries.map { it.fileName.toString() }.sorted()
                }
                children.flatMap { selectedRemovalFiles("$address/$it", context) } + address
            }
        } catch (_: IOException) { listOf(address) }
    }
    private fun selectedAttributes(address: String): java.nio.file.attribute.BasicFileAttributes? {
        try {
            val rootAttributes = Files.readAttributes(root.toPath(), java.nio.file.attribute.BasicFileAttributes::class.java,
                LinkOption.NOFOLLOW_LINKS)
            if (!rootAttributes.isDirectory) throw MonitorMediaCacheException(MonitorMediaCacheFailure.INVALID_ADDRESS)
            var location = root.toPath()
            val pieces = address.split('/')
            pieces.forEachIndexed { index, piece ->
                location = location.resolve(piece)
                val info = Files.readAttributes(location, java.nio.file.attribute.BasicFileAttributes::class.java,
                    LinkOption.NOFOLLOW_LINKS)
                val last = index == pieces.lastIndex
                if (if (last) !info.isRegularFile && !info.isDirectory else !info.isDirectory) {
                    throw MonitorMediaCacheException(MonitorMediaCacheFailure.INVALID_ADDRESS)
                }
                if (last) return info
            }
            throw MonitorMediaCacheException(MonitorMediaCacheFailure.INVALID_ADDRESS)
        } catch (_: NoSuchFileException) { return null }
    }
    private fun retiredRoots(includeUnprepared: Boolean): List<File> = root.parentFile?.listFiles().orEmpty().filter {
        // Reject unrelated siblings before asking the filesystem for metadata.
        (isRetirementName(it.name, ".clearing-${root.name}-") ||
            (includeUnprepared && (isRetirementName(it.name, ".retiring-${root.name}-") ||
                (accountLegacyUnpreparedRoots && it.name.startsWith(".retiring-${root.name}-"))))) &&
            MonitorMediaCacheNamespaces.isDirectory(it)
    }
    private fun isRetirementName(name: String, prefix: String): Boolean {
        if (!name.startsWith(prefix)) return false
        val suffix = name.removePrefix(prefix)
        // UUID.fromString also accepts abbreviated groups. Require the entire canonical suffix.
        return runCatching { UUID.fromString(suffix).toString().equals(suffix, ignoreCase = true) }.getOrDefault(false)
    }
}

/**
 * Shot color codes by clip path (`color.json`), metadata a catalog clear may keep or drop. The map is
 * cached per directory generation, so a clear is never answered from memory, and a writer admitted
 * at an older generation never recreates cleared metadata.
 */
public class MonitorMediaShotColorStore internal constructor(private val directory: MonitorMediaCacheDirectory) {
    private var map: Map<String, Int> = emptyMap()
    private var mapGeneration: Long? = null

    /** Read-only: never migrates or recreates cleared metadata. */
    @Synchronized public fun color(path: String): Int? = load()[path]

    /** Admitted only while the directory is still at [generation]; negative codes are not colors. */
    @Synchronized public fun remember(path: String, code: Int, generation: Long = directory.generation) {
        if (code >= 0) persist(generation) { it + (path to code) }
    }

    /** One-time import of an app's legacy codes; codes already stored win. */
    @Synchronized public fun adopt(legacy: Map<String, Int>) {
        persist(directory.generation) { stored -> legacy.filterValues { it >= 0 } + stored }
    }

    private fun load(): Map<String, Int> {
        val generation = directory.generation
        if (mapGeneration == generation) return map
        map = runCatching {
            val json = JSONObject(directory.read(ADDRESS).toString(Charsets.UTF_8))
            json.keys().asSequence().associateWith { json.optInt(it, -1) }.filterValues { it >= 0 }
        }.getOrDefault(emptyMap())
        mapGeneration = generation
        return map
    }

    private fun persist(generation: Long, change: (Map<String, Int>) -> Map<String, Int>) {
        if (directory.generation != generation) return
        val next = change(load())
        val bytes = JSONObject(next).toString().toByteArray(Charsets.UTF_8)
        // The lease is taken at the admitted generation, so a clear before commit retires it.
        val writer = synchronized(directory.lock) {
            if (directory.revision != generation) return
            directory.beginWrite(ADDRESS)
        }
        try { writer.writeNow(bytes); writer.commit(MediaTransferReceipt(bytes.size.toLong())) }
        catch (_: MonitorMediaCacheException) { return }
        finally { writer.abort() }
        map = next; mapGeneration = generation
    }

    private companion object { const val ADDRESS = "color.json" }
}

/** Abort only removes its unique staging path. A retired writer can never commit into a new root. */
public class MonitorMediaCacheWrite internal constructor(
    private val directory: MonitorMediaCacheDirectory, private val id: UUID, private val generation: Long,
    private val destination: File, private val resource: MonitorMediaCacheDirectory.Resource,
    private val writeOperation: (FileOutputStream, ByteArray) -> Unit,
) : MediaByteSink, AutoCloseable {
    private var bytes = 0L
    private var finished = false
    private fun check() {
        if (finished || directory.revision != generation || directory.current[destination.path] != id) {
            throw MonitorMediaCacheException(MonitorMediaCacheFailure.RETIRED)
        }
    }
    internal fun writeNow(chunk: ByteArray) = resource.withIO {
        synchronized(directory.lock) { check() }
        writeOperation(resource.stream, chunk)
        synchronized(directory.lock) { check() }
        bytes += chunk.size
    }
    override suspend fun write(chunk: ByteArray) { currentCoroutineContext().ensureActive(); writeNow(chunk) }
    public fun commit(receipt: MediaTransferReceipt): File = resource.withIO {
        synchronized(directory.lock) { check() }
        if (bytes <= 0) throw MonitorMediaCacheException(MonitorMediaCacheFailure.EMPTY)
        if (bytes != receipt.byteCount) throw MonitorMediaCacheException(MonitorMediaCacheFailure.INVALID_RECEIPT)
        resource.close()
        synchronized(directory.lock) {
            // Close may have blocked while retirement invalidated this lease.
            check()
            if (destination.exists() && !destination.delete()) throw IOException("Cannot replace cache file")
            if (!resource.temporary.renameTo(destination)) throw IOException("Cannot commit cache file")
            finished = true; directory.current.remove(destination.path); directory.resources.remove(id)
            destination
        }
    }
    public fun abort() {
        val retired = synchronized(directory.lock) {
            if (finished) null else {
                finished = true
                val owned = directory.resources.remove(id)
                // Clear/supersession removed the registration before rebinding the root.
                // Never use that old staging URL against a later live directory.
                owned?.temporary?.delete()
                if (directory.current[destination.path] == id) directory.current.remove(destination.path)
                owned
            }
        }
        retired?.requestClose()
    }
    override fun close() { abort() }
}

/** Schema, root lifetime and size policy are supplied by the actual app composition. */
internal data class MonitorMediaCatalogAuthority(val owner: UUID, val directoryGeneration: Long,
    val storeNamespace: String?, val storeGeneration: Long?)
public class MonitorMediaCache<P>(
    public val directory: MonitorMediaCacheDirectory,
    public val codec: MonitorMediaCatalogCodec<P>,
    public val eligibility: MonitorMediaOriginalEligibility,
    private val catalogAddress: String,
    private val preservedMetadata: List<String>,
    private val persistEmptyCatalog: Boolean = true,
    public val catalogStore: MonitorMediaCatalogByteStore? = null,
) {
    private val catalogOwner = UUID.randomUUID()
    internal val catalogAuthority: MonitorMediaCatalogAuthority get() = MonitorMediaCatalogAuthority(
        catalogOwner, directory.generation, catalogStore?.namespace, catalogStore?.generation)
    internal fun isCurrent(authority: MonitorMediaCatalogAuthority): Boolean = catalogAuthority == authority
    public fun load(): List<MonitorMediaRecord<P>> = runCatching {
        val namespace = catalogStore?.namespace; val generation = catalogStore?.generation
        val bytes = if (catalogStore != null) {
            val bytes = catalogStore.read()?.copyOf()
            if (catalogStore.namespace != namespace || catalogStore.generation != generation) return@runCatching emptyList()
            bytes
        } else directory.read(catalogAddress)
        val records = if (bytes == null) emptyList() else codec.decode(bytes)
        if (catalogStore?.namespace != namespace || catalogStore?.generation != generation) emptyList() else records
    }.getOrElse { emptyList() }
    public fun save(records: List<MonitorMediaRecord<P>>, ifCurrent: () -> Boolean = { true }) {
        if (!ifCurrent()) throw MonitorMediaCacheException(MonitorMediaCacheFailure.RETIRED)
        if (!persistEmptyCatalog && records.isEmpty()) return
        val directoryGeneration = directory.generation
        if (catalogStore != null) {
            val namespace = catalogStore.namespace; val generation = catalogStore.generation
            val admitted = { ifCurrent() && directory.generation == directoryGeneration
                && catalogStore.namespace == namespace && catalogStore.generation == generation }
            catalogStore.update(admitted) { currentBytes ->
                if (!admitted()) throw MonitorMediaCacheException(MonitorMediaCacheFailure.RETIRED)
                val bytes = codec.encodeForPersistence(records, currentBytes)
                if (!admitted()) throw MonitorMediaCacheException(MonitorMediaCacheFailure.RETIRED)
                bytes
            }
            if (!admitted()) throw MonitorMediaCacheException(MonitorMediaCacheFailure.RETIRED)
        } else {
            val bytes = codec.encode(records)
            if (!ifCurrent() || directory.generation != directoryGeneration) throw MonitorMediaCacheException(MonitorMediaCacheFailure.RETIRED)
            directory.write(bytes, catalogAddress)
        }
    }
    public fun entry(record: MonitorMediaRecord<P>): MonitorMediaCacheEntry {
        var original: File? = null; var proxy: File? = null
        record.asset.representations.forEach { representation ->
            val address = record.address.representations[representation.id] ?: return@forEach
            val candidates = listOf(address) + record.address.readAlternatives[representation.id].orEmpty()
            val location = candidates.asSequence().mapNotNull { directory.existing(it) }.firstOrNull {
                representation.role != MediaRepresentationRole.ORIGINAL || eligibility.accepts(it.length(), representation.byteCount)
            } ?: return@forEach
            if (representation.role == MediaRepresentationRole.ORIGINAL) {
                if (eligibility.accepts(location.length(), representation.byteCount)) original = location
            } else if (proxy == null) proxy = location
        }
        return MonitorMediaCacheEntry(original, proxy, record.address.thumbnail?.let { directory.existing(it) })
    }
    /** Only immutable paths and size facts are captured; filesystem reads run on IO. */
    public fun readPlan(records: List<MonitorMediaRecord<P>>): MonitorMediaCacheReadPlan {
        val plan = records.map { record ->
            MediaCacheRecordReadPlan(record.asset.id,
                record.address.thumbnail?.let { runCatching { directory.file(it) }.getOrNull() },
                record.asset.representations.map { representation ->
                    val canonical = record.address.representations[representation.id]
                    val addresses = canonical?.let { listOf(it) + record.address.readAlternatives[representation.id].orEmpty() }.orEmpty()
                    MediaCacheRepresentationReadPlan(representation.role, representation.byteCount,
                        addresses.mapNotNull { runCatching { directory.file(it) }.getOrNull() })
                })
        }
        return MonitorMediaCacheReadPlan(UUID.randomUUID(), directory.generation, plan, eligibility)
    }
    public suspend fun snapshot(records: List<MonitorMediaRecord<P>>): MonitorMediaCacheSnapshot = readPlan(records).read()
    public suspend fun clear() { clear(preservingMetadata = true) }
    /** Settings can remove indexes with the clips; the original no-argument contract keeps them. */
    public suspend fun clear(preservingMetadata: Boolean) {
        directory.clear(if (preservingMetadata) preservedMetadata else emptyList())
    }
}


/** Admission identity accompanies the immutable worker result. */
public class MonitorMediaCacheSnapshot internal constructor(
    public val planID: UUID, public val generation: Long,
    public val entries: Map<MediaAssetID, MonitorMediaCacheEntry>,
)
internal data class MediaCacheRepresentationReadPlan(
    val role: MediaRepresentationRole, val expected: Long?, val locations: List<File>,
)
internal data class MediaCacheRecordReadPlan(
    val id: MediaAssetID, val thumbnail: File?, val representations: List<MediaCacheRepresentationReadPlan>,
)

/** No live codec, source catalog or owner state is read by the filesystem worker. */
public class MonitorMediaCacheReadPlan internal constructor(
    public val id: UUID, public val generation: Long,
    private val records: List<MediaCacheRecordReadPlan>, private val eligibility: MonitorMediaOriginalEligibility,
) {
    /** The records this plan covers, in plan order (scan accounting; no filesystem access). */
    internal val recordIDs: List<MediaAssetID> get() = records.map { it.id }
    public suspend fun read(): MonitorMediaCacheSnapshot = withContext(Dispatchers.IO) {
        val entries = linkedMapOf<MediaAssetID, MonitorMediaCacheEntry>()
        records.forEach { record ->
            currentCoroutineContext().ensureActive()
            var original: File? = null; var proxy: File? = null
            record.representations.forEach { representation ->
                for (location in representation.locations) {
                    currentCoroutineContext().ensureActive()
                    if (!location.isFile || location.length() <= 0) continue
                    if (representation.role == MediaRepresentationRole.ORIGINAL) {
                        if (eligibility.accepts(location.length(), representation.expected)) { original = location; break }
                    } else if (proxy == null) { proxy = location; break }
                }
            }
            val thumbnail = record.thumbnail?.takeIf { it.isFile && it.length() > 0 }
            entries[record.id] = MonitorMediaCacheEntry(original, proxy, thumbnail)
        }
        currentCoroutineContext().ensureActive()
        MonitorMediaCacheSnapshot(id, generation, entries.toMap())
    }
}
