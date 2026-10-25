package com.opencapture.opencine.media

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.FileTime
import java.security.MessageDigest

/** Base class for a clip that cannot safely enter the Android share flow. */
public sealed class MonitorMediaShareException(message: String, cause: Throwable? = null) :
    IOException(message, cause)

/** A share was requested before the progressive cache published its final file. */
public class IncompleteMonitorMediaShareException(
    /** The cache state that rejected the request. */
    public val cacheState: ProgressiveMediaCacheState,
) : MonitorMediaShareException("Clip is not fully cached (state: $cacheState).")

/** The camera filename is not safe to use as share-sheet display metadata. */
public class UnsafeMonitorMediaShareFilenameException(filename: String) :
    MonitorMediaShareException("Unsafe camera media filename for sharing: $filename")

/** The published cache file was missing, mutable, or did not match the camera byte count. */
public class InvalidMonitorMediaShareSourceException(message: String) : MonitorMediaShareException(message)

/** The temporary share cache cannot safely make room for another completed clip. */
public class MonitorMediaShareCacheLimitException(message: String) : MonitorMediaShareException(message)

/** Returns whether [filename] is safe to use as external media display metadata. */
public fun isSafeMonitorMediaDisplayName(filename: String): Boolean =
    !(
        filename.isBlank() ||
            filename != filename.trim() ||
            filename == "." ||
            filename == ".." ||
            filename.indexOf('\u0000') >= 0 ||
            filename.contains('/') ||
            filename.contains('\\') ||
            filename.any { character -> character.code < 0x20 || character.code == 0x7F } ||
            filename.substringBeforeLast('.', missingDelimiterValue = "").isBlank()
    )

/**
 * A fully copied share artifact held below app-owned `cacheDir/share/ready`.
 *
 * [file] is deliberately not the no-backup progressive cache file. The Android
 * `FileProvider` exposes only this ready directory, while [displayName] keeps
 * the camera's validated filename available to the receiving app.
 */
public data class MonitorStagedMediaShare(
    /** App-cache file that may be handed to the Android `FileProvider`. */
    public val file: Path,
    /** Validated camera filename shown by the receiving app. */
    public val displayName: String,
    /** MIME family from the core action when available, otherwise generic media. */
    public val mimeType: String,
)

/** Immutable host retention and capacity facts for provider-visible complete artifacts. */
public data class MonitorMediaShareStagingPolicy(
    public val maximumReadyBytes: Long,
    public val maximumReadyArtifacts: Int,
    public val grantRetentionMillis: Long,
    public val copyBufferBytes: Int,
)

/**
 * Copies only complete progressive-cache entries into an app-cache directory
 * intentionally scoped for Android sharing.
 *
 * The progressive cache belongs under `noBackupFilesDir`; this class accepts
 * its immutable final file but never returns that path. Its provider-visible
 * files live exclusively below `cacheDir/share/ready`, while transient copy
 * files remain in the sibling, provider-inaccessible `share/staging` folder.
 *
 * A ready artifact is retained for the supplied grace period after each successful
 * staging request. This interval protects the asynchronous temporary
 * URI grant made when Android opens the chooser: recipients must copy the
 * content while that grant is active, rather than treating this cache URI as
 * durable storage. The supplied capacity bounds bytes and artifact count;
 * if this owner cannot make room without violating the grace interval, staging fails
 * instead of deleting a possibly granted artifact.
 *
 * @param cacheDirectory The app's scoped `Context.cacheDir` path.
 */
public class MonitorMediaShareStager(
    cacheDirectory: Path,
    policy: MonitorMediaShareStagingPolicy,
    clock: () -> Long = System::currentTimeMillis,
) {
    private val clock: () -> Long = clock
    private val maximumReadyBytes: Long = policy.maximumReadyBytes
    private val maximumReadyArtifacts: Int = policy.maximumReadyArtifacts
    private val grantRetentionMillis: Long = policy.grantRetentionMillis
    private val copyBufferBytes: Int = policy.copyBufferBytes
    private val cacheDirectory: Path = cacheDirectory.toAbsolutePath().normalize()
    private val shareDirectory: Path = containedDirectory(this.cacheDirectory, "share")
    private val readyDirectory: Path = containedDirectory(shareDirectory, "ready")
    private val stagingDirectory: Path = containedDirectory(shareDirectory, "staging")

    init {
        require(maximumReadyBytes > 0) { "maximumReadyBytes must be positive." }
        require(maximumReadyArtifacts > 0) { "maximumReadyArtifacts must be positive." }
        require(grantRetentionMillis >= 0) { "grantRetentionMillis must not be negative." }
        require(copyBufferBytes > 0) { "copyBufferBytes must be positive." }
        ensureDirectory(this.cacheDirectory)
        ensureDirectory(shareDirectory)
        ensureDirectory(readyDirectory)
        ensureDirectory(stagingDirectory)
    }

    /**
     * Publishes an already-complete app-owned export into the same bounded
     * FileProvider-ready cache as camera originals. The source is copied and
     * content-verified; callers may safely delete their transient export once
     * this method returns.
     */
    public fun stagePreparedArtifact(
        source: Path,
        expectedBytes: Long,
        displayName: String,
        mimeType: String,
        cancellationCheck: () -> Unit = {},
    ): MonitorStagedMediaShare {
        validateFilename(displayName)
        if (expectedBytes <= 0 || !mimeType.matches(SAFE_MIME_TYPE)) {
            throw InvalidMonitorMediaShareSourceException("The prepared delivery artifact is invalid.")
        }
        val normalizedSource = source.toAbsolutePath().normalize()
        if (
            normalizedSource.fileName.toString().endsWith(".part") ||
                !Files.isRegularFile(normalizedSource, LinkOption.NOFOLLOW_LINKS) ||
                Files.isSymbolicLink(normalizedSource) ||
                Files.size(normalizedSource) != expectedBytes
        ) {
            throw InvalidMonitorMediaShareSourceException("The prepared delivery artifact is incomplete.")
        }
        return stageCompleteSource(
            source = normalizedSource,
            expectedLength = expectedBytes,
            filename = displayName,
            mimeType = mimeType,
            cancellationCheck = cancellationCheck,
        )
    }

    public fun stage(
        entry: ProgressiveMediaCacheEntry,
        filename: String,
        mimeType: String,
        cancellationCheck: () -> Unit = {},
    ): MonitorStagedMediaShare {
        validateFilename(filename)
        if (!mimeType.matches(SAFE_MIME_TYPE) && !mimeType.matches(SAFE_MIME_FAMILY)) {
            throw InvalidMonitorMediaShareSourceException("The prepared delivery artifact is invalid.")
        }
        ensureComplete(entry)
        cancellationCheck()

        val source = entry.finalPath.toAbsolutePath().normalize()
        validatePublishedSourcePath(entry, source)

        return stageCompleteSource(
            source = source,
            expectedLength = entry.expectedLength,
            filename = filename,
            mimeType = mimeType,
            cancellationCheck = cancellationCheck,
        )
    }

    private fun stageCompleteSource(
        source: Path,
        expectedLength: Long,
        filename: String,
        mimeType: String,
        cancellationCheck: () -> Unit,
    ): MonitorStagedMediaShare {
        val temporary = Files.createTempFile(stagingDirectory, "share-", ".tmp")
        var movedTarget: Path? = null
        var targetWasPublished = false
        try {
            val copied =
                copySourceToTemporary(
                    source = source,
                    expectedLength = expectedLength,
                    temporary = temporary,
                    cancellationCheck = cancellationCheck,
                )
            val target = targetPath(copied.contentDigest, filename)

            synchronized(readyCacheLock) {
                cancellationCheck()
                val now = clock()
                if (isUsableReadyCopy(target, copied, cancellationCheck)) {
                    markReadyForGrant(target, now)
                    reclaimReadyCache(
                        protectedPath = target,
                        incomingBytes = 0,
                        incomingArtifacts = 0,
                        now = now,
                        cancellationCheck = cancellationCheck,
                    )
                    return MonitorStagedMediaShare(target, filename, mimeType)
                }

                replaceUnusableTargetIfExpired(target, now)
                reclaimReadyCache(
                    protectedPath = target,
                    incomingBytes = copied.byteCount,
                    incomingArtifacts = 1,
                    now = now,
                    cancellationCheck = cancellationCheck,
                )
                cancellationCheck()
                ensureDirectory(target.parent)
                // `ready` is FileProvider-visible, so only an atomically published,
                // complete file may enter it. Both directories are below cacheDir.
                Files.move(
                    temporary,
                    target,
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
                movedTarget = target
                markReadyForGrant(target, now)
                targetWasPublished = true
                return MonitorStagedMediaShare(target, filename, mimeType)
            }
        } finally {
            if (!targetWasPublished) {
                runCatching { Files.deleteIfExists(temporary) }
                movedTarget?.let { target -> runCatching { deleteReadyFile(target) } }
                synchronized(readyCacheLock) { removeEmptyArtifactDirectories() }
            }
        }
    }

    private fun ensureComplete(entry: ProgressiveMediaCacheEntry) {
        if (entry.state != ProgressiveMediaCacheState.COMPLETE || entry.downloadedBytes != entry.expectedLength) {
            throw IncompleteMonitorMediaShareException(entry.state)
        }
    }

    private fun validatePublishedSourcePath(entry: ProgressiveMediaCacheEntry, source: Path) {
        val partial = entry.partialPath.toAbsolutePath().normalize()
        if (source == partial || source.fileName.toString().endsWith(".part")) {
            throw InvalidMonitorMediaShareSourceException("A progressive .part file cannot be shared.")
        }
        if (!Files.isRegularFile(source, LinkOption.NOFOLLOW_LINKS)) {
            throw InvalidMonitorMediaShareSourceException("The completed camera cache file is unavailable.")
        }
        val sourceLength = Files.size(source)
        if (sourceLength != entry.expectedLength) {
            throw InvalidMonitorMediaShareSourceException(
                "Completed camera cache length changed " +
                    "(expected ${entry.expectedLength} bytes, found $sourceLength).",
            )
        }
    }

    /**
     * Opens the source once with `NOFOLLOW_LINKS` and copies from that handle.
     *
     * The preflight path validation above is intentionally not trusted for the
     * copy: a replacement after validation cannot redirect this already-open
     * file descriptor to a symlink or a different path entry.
     */
    private fun copySourceToTemporary(
        source: Path,
        expectedLength: Long,
        temporary: Path,
        cancellationCheck: () -> Unit,
    ): CopiedMediaSource =
        FileChannel.open(source, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use { sourceChannel ->
            cancellationCheck()
            val openedLength = sourceChannel.size()
            if (openedLength != expectedLength) {
                throw InvalidMonitorMediaShareSourceException(
                    "Completed camera cache length changed after opening " +
                        "(expected $expectedLength bytes, found $openedLength).",
                )
            }

            FileChannel.open(temporary, StandardOpenOption.READ, StandardOpenOption.WRITE, StandardOpenOption.TRUNCATE_EXISTING).use {
                targetChannel ->
                val digest = MessageDigest.getInstance("SHA-256")
                val buffer = ByteBuffer.allocate(copyBufferBytes)
                var copiedBytes = 0L
                while (copiedBytes < expectedLength) {
                    cancellationCheck()
                    buffer.clear()
                    buffer.limit(
                        minOf(
                            buffer.capacity().toLong(),
                            expectedLength - copiedBytes,
                        ).toInt(),
                    )
                    val read = sourceChannel.read(buffer)
                    if (read < 0) {
                        throw InvalidMonitorMediaShareSourceException(
                            "Completed camera cache ended before $expectedLength bytes were copied.",
                        )
                    }
                    if (read == 0) continue

                    buffer.flip()
                    digest.update(buffer.asReadOnlyBuffer())
                    while (buffer.hasRemaining()) {
                        cancellationCheck()
                        targetChannel.write(buffer)
                    }
                    copiedBytes += read.toLong()
                }

                cancellationCheck()
                if (sourceChannel.size() != expectedLength || Files.size(temporary) != expectedLength) {
                    throw InvalidMonitorMediaShareSourceException(
                        "Cached clip changed while preparing the share copy " +
                            "(expected $expectedLength bytes).",
                    )
                }
                verifyEnteredCopy(sourceChannel, targetChannel, expectedLength, cancellationCheck)
                CopiedMediaSource(byteCount = copiedBytes, contentDigest = hex(digest.digest()))
            }
        }

    /** Compare the private copy with the entered handle; a path replacement cannot redirect it. */
    private fun verifyEnteredCopy(
        source: FileChannel, copy: FileChannel, expectedLength: Long, cancellationCheck: () -> Unit,
    ) {
        source.position(0)
        copy.position(0)
        val original = ByteBuffer.allocate(copyBufferBytes)
        val staged = ByteBuffer.allocate(copyBufferBytes)
        var compared = 0L
        while (compared < expectedLength) {
            cancellationCheck()
            val count = minOf(copyBufferBytes.toLong(), expectedLength - compared).toInt()
            original.clear().limit(count)
            staged.clear().limit(count)
            while (original.hasRemaining()) {
                cancellationCheck()
                if (source.read(original) < 0) throw changedEnteredSource()
            }
            while (staged.hasRemaining()) {
                cancellationCheck()
                if (copy.read(staged) < 0) throw changedEnteredSource()
            }
            original.flip()
            staged.flip()
            if (original != staged) throw changedEnteredSource()
            compared += count.toLong()
        }
        if (source.size() != expectedLength || copy.size() != expectedLength) throw changedEnteredSource()
    }

    private fun changedEnteredSource(): InvalidMonitorMediaShareSourceException =
        InvalidMonitorMediaShareSourceException("Cached clip changed while preparing the share copy.")

    private fun isUsableReadyCopy(
        path: Path,
        copied: CopiedMediaSource,
        cancellationCheck: () -> Unit,
    ): Boolean {
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) return false
        return try {
            FileChannel.open(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use { channel ->
                if (channel.size() != copied.byteCount) return@use false
                val digest = MessageDigest.getInstance("SHA-256")
                val buffer = ByteBuffer.allocate(copyBufferBytes)
                while (true) {
                    cancellationCheck()
                    buffer.clear()
                    val read = channel.read(buffer)
                    if (read < 0) break
                    if (read == 0) continue
                    buffer.flip()
                    digest.update(buffer)
                }
                hex(digest.digest()) == copied.contentDigest
            }
        } catch (_: IOException) {
            false
        }
    }

    /**
     * Keeps an unusable artifact intact while its temporary FileProvider grant
     * may still be in use. Even a corrupt content-addressed file can belong to
     * a recipient that has not finished reading its granted URI yet.
     */
    private fun replaceUnusableTargetIfExpired(target: Path, now: Long) {
        if (!Files.exists(target, LinkOption.NOFOLLOW_LINKS)) return
        val existing =
            readyArtifact(target)
                ?: throw InvalidMonitorMediaShareSourceException(
                    "Existing share artifact cannot be safely inspected for replacement.",
                )
        if (!existing.isExpired(now)) {
            throw MonitorMediaShareCacheLimitException(
                "An existing share artifact is still within its URI-grant retention window.",
            )
        }
        if (!deleteReadyFile(target)) {
            throw InvalidMonitorMediaShareSourceException(
                "Existing share artifact disappeared before it could be safely replaced.",
            )
        }
    }

    /** Reclaims only artifacts that have outlived the documented URI-grant grace period. */
    private fun reclaimReadyCache(
        protectedPath: Path,
        incomingBytes: Long,
        incomingArtifacts: Int,
        now: Long,
        cancellationCheck: () -> Unit,
    ) {
        var retainedBytes = 0L
        var retainedArtifacts = 0
        val artifacts = readyArtifacts()
        artifacts.forEach { artifact ->
            retainedBytes = saturatingAdd(retainedBytes, artifact.byteCount)
            retainedArtifacts += 1
        }

        val evictionCandidates =
            artifacts
                .asSequence()
                .filter { artifact -> artifact.path != protectedPath && artifact.isExpired(now) }
                .sortedWith(compareBy<ReadyArtifact>({ it.lastGrantedAtMillis }, { it.path.fileName.toString() }))
                .iterator()

        while (exceedsReadyCapacity(retainedBytes, retainedArtifacts, incomingBytes, incomingArtifacts) &&
            evictionCandidates.hasNext()
        ) {
            cancellationCheck()
            val artifact = evictionCandidates.next()
            if (deleteReadyFile(artifact.path)) {
                retainedBytes = (retainedBytes - artifact.byteCount).coerceAtLeast(0)
                retainedArtifacts -= 1
            }
        }

        if (incomingArtifacts > 0 &&
            exceedsReadyCapacity(retainedBytes, retainedArtifacts, incomingBytes, incomingArtifacts)
        ) {
            throw MonitorMediaShareCacheLimitException(
                "The temporary share cache is full; existing URI grants are still within their retention window.",
            )
        }
    }

    /**
     * Every provider-visible artifact: `ready/<digest>/<camera filename>`, plus flat
     * `ready/<digest>.<ext>` files left by builds that named copies by digest alone. Other
     * folders below `ready` (an app's own diagnostics or log shares) are not this owner's.
     */
    private fun readyArtifacts(): List<ReadyArtifact> {
        val artifacts = mutableListOf<ReadyArtifact>()
        fun collect(directory: Path, nested: Boolean) {
            Files.list(directory).use { paths ->
                val iterator = paths.iterator()
                while (iterator.hasNext()) {
                    val path = iterator.next()
                    if (Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) {
                        readyArtifact(path)?.let { artifacts += it }
                    } else if (!nested && isArtifactDirectory(path)) {
                        collect(path, nested = true)
                    }
                }
            }
        }
        collect(readyDirectory, nested = false)
        return artifacts
    }

    private fun isArtifactDirectory(path: Path): Boolean =
        Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS) && path.fileName.toString().matches(DIGEST_NAME)

    /** Removes one ready file and the digest folder it leaves empty. */
    private fun deleteReadyFile(path: Path): Boolean {
        val deleted = Files.deleteIfExists(path)
        val folder = path.parent
        if (folder != null && folder.parent == readyDirectory && isArtifactDirectory(folder)) {
            runCatching { Files.deleteIfExists(folder) } // Still holds a twin under another name.
        }
        return deleted
    }

    /** Digest folders a failed or cancelled publish created but never filled. */
    private fun removeEmptyArtifactDirectories() {
        Files.list(readyDirectory).use { paths ->
            val iterator = paths.iterator()
            while (iterator.hasNext()) {
                val path = iterator.next()
                if (isArtifactDirectory(path)) {
                    runCatching { Files.deleteIfExists(path) }
                }
            }
        }
    }

    private fun readyArtifact(path: Path): ReadyArtifact? {
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) return null
        return try {
            ReadyArtifact(
                path = path,
                byteCount = Files.size(path),
                lastGrantedAtMillis =
                    Files.getLastModifiedTime(path, LinkOption.NOFOLLOW_LINKS).toMillis(),
            )
        } catch (_: IOException) {
            null
        }
    }

    private fun ReadyArtifact.isExpired(now: Long): Boolean =
        lastGrantedAtMillis <= now - grantRetentionMillis

    private fun exceedsReadyCapacity(
        retainedBytes: Long,
        retainedArtifacts: Int,
        incomingBytes: Long,
        incomingArtifacts: Int,
    ): Boolean =
        saturatingAdd(retainedBytes, incomingBytes) > maximumReadyBytes ||
            retainedArtifacts > maximumReadyArtifacts - incomingArtifacts

    private fun markReadyForGrant(path: Path, now: Long) {
        Files.setLastModifiedTime(path, FileTime.fromMillis(now))
    }

    /**
     * `ready/<digest>/<camera filename>`: the digest keeps distinct content apart, and the last
     * path segment is what FileProvider reports as the shared file's name to the receiving app.
     */
    private fun targetPath(contentDigest: String, filename: String): Path =
        readyDirectory.resolve(contentDigest).resolve(filename).normalize().also { path ->
            if (path.parent?.parent != readyDirectory) {
                throw InvalidMonitorMediaShareSourceException("Share artifact escaped the ready directory.")
            }
        }

    private fun containedDirectory(parent: Path, name: String): Path =
        parent.resolve(name).normalize().also { path ->
            if (path.parent != parent) {
                throw InvalidMonitorMediaShareSourceException("Share directory escaped its app-cache root.")
            }
        }

    private fun ensureDirectory(path: Path) {
        Files.createDirectories(path)
        if (!Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(path)) {
            throw InvalidMonitorMediaShareSourceException("Share directory is not a safe app-cache directory.")
        }
    }

    private fun validateFilename(filename: String) {
        if (!isSafeMonitorMediaDisplayName(filename)) {
            throw UnsafeMonitorMediaShareFilenameException(filename)
        }
    }

    private fun saturatingAdd(first: Long, second: Long): Long =
        if (first > Long.MAX_VALUE - second) Long.MAX_VALUE else first + second

    private fun hex(bytes: ByteArray): String {
        val hex = "0123456789abcdef"
        return buildString(bytes.size * 2) {
            bytes.forEach { byte ->
                val unsigned = byte.toInt() and 0xFF
                append(hex[unsigned ushr 4])
                append(hex[unsigned and 0x0F])
            }
        }
    }

    private data class CopiedMediaSource(
        val byteCount: Long,
        val contentDigest: String,
    )

    private data class ReadyArtifact(
        val path: Path,
        val byteCount: Long,
        val lastGrantedAtMillis: Long,
    )

    private companion object {
        val SAFE_MIME_TYPE: Regex = Regex("[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+*-]*")
        val SAFE_MIME_FAMILY: Regex = Regex("[a-z0-9][a-z0-9.+-]*/\\*")
        val DIGEST_NAME: Regex = Regex("[0-9a-f]{64}")

        /** Serializes ready-cache publication and eviction across stager instances in this process. */
        val readyCacheLock: Any = Any()
    }
}

public data class MonitorMediaShareIntentSpec(
    public val action: String,
    public val mimeType: String,
    public val streamExtraIncluded: Boolean,
    public val clipDataLabel: String,
    public val grantsReadUriPermission: Boolean,
    public val chooserTitle: String,
    /** The "Include metadata" summary sent as `EXTRA_TEXT` beside the files, when not blank. */
    public val text: String? = null,
) {
    public companion object {
        /** Builds the immutable policy for one staged clip. */
        public fun forShare(share: MonitorStagedMediaShare, batchLabel: String): MonitorMediaShareIntentSpec = forShares(listOf(share), batchLabel)

        /**
         * Builds the immutable policy for one or more already-staged artifacts.
         *
         * Mixed camera media deliberately uses a wildcard MIME type: every individual URI
         * keeps its filename extension and FileProvider type, while a narrow
         * shared MIME type would hide one of the selected assets from many
         * native share targets.
         */
        public fun forShares(shares: List<MonitorStagedMediaShare>, batchLabel: String,
            metadataText: String? = null): MonitorMediaShareIntentSpec {
            require(shares.isNotEmpty()) { "At least one staged media file is required." }
            val first = shares.first()
            val single = shares.size == 1
            return MonitorMediaShareIntentSpec(
                action = if (single) ACTION_SEND else ACTION_SEND_MULTIPLE,
                mimeType =
                    shares.map(MonitorStagedMediaShare::mimeType).distinct().singleOrNull() ?: "*/*",
                streamExtraIncluded = true,
                clipDataLabel = if (single) first.displayName else batchLabel,
                grantsReadUriPermission = true,
                chooserTitle =
                    if (single) "Share ${first.displayName}" else "Share ${shares.size} items",
                text = metadataText?.takeIf { it.isNotBlank() },
            )
        }

        /** Android's canonical `ACTION_SEND` string, kept JVM-testable here. */
        public const val ACTION_SEND: String = "android.intent.action.SEND"

        /** Android's canonical multi-stream share action, kept JVM-testable here. */
        public const val ACTION_SEND_MULTIPLE: String = "android.intent.action.SEND_MULTIPLE"
    }
}
