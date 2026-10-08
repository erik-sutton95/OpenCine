package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.MediaAssetID
import com.opencapture.opencine.media.MediaByteSink
import com.opencapture.opencine.media.MediaServiceException
import com.opencapture.opencine.media.MediaServiceFailure
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlin.coroutines.CoroutineContext

/** Opaque source grouping, independent of catalog identity; unindexed IO never inserts rows. */
public data class MonitorMediaLibraryIOKey(public val rawValue: String)
public enum class MonitorMediaLibraryIOPurpose {
    THUMBNAIL, DOWNLOAD, PLAYBACK, ORIGINAL_IMAGE, DELETION;

    internal val tracksProgress: Boolean get() = this == DOWNLOAD || this == PLAYBACK
}

/** Captured library, content, root and SDK admission on the presentation owner. */
public class MonitorMediaLibraryIOAuthority internal constructor(
    internal val owner: UUID,
    public val key: MonitorMediaLibraryIOKey,
    public val asset: MediaAssetID?,
    public val directory: MonitorMediaCacheDirectory,
    private val admitted: () -> Boolean,
) {
    public val id: UUID = UUID.randomUUID()
    public val generation: Long = directory.generation
    public val isCurrent: Boolean get() {
        if (directory.generation != generation) return false
        val allowed = admitted()
        return allowed && directory.generation == generation
    }
    public fun requireCurrent() {
        if (!isCurrent) throw MediaServiceException(MediaServiceFailure.RETIRED)
    }
}

/** File reads stay on IO; captured sink admission remains on the supplied presentation owner. */
internal object MonitorMediaLibraryFileCopy {
    suspend fun copy(source: File, sink: MediaByteSink, ownerContext: CoroutineContext): Long =
        withContext(Dispatchers.IO) {
            var count = 0L
            source.inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val length = input.read(buffer)
                    if (length < 0) break
                    if (length > 0) {
                        val chunk = buffer.copyOf(length)
                        withContext(ownerContext) { sink.write(chunk) }
                        count += length
                    }
                }
            }
            count
        }
}

/** Private attempt staging, not a second cache or transfer-policy owner. */
internal class LibraryHostFileSink(location: File) : MediaByteSink, AutoCloseable {
    private var output: FileOutputStream?
    init { location.parentFile?.mkdirs(); output = FileOutputStream(location) }
    override suspend fun write(chunk: ByteArray) = withContext(Dispatchers.IO) {
        currentCoroutineContext().ensureActive()
        writeBytes(chunk)
    }
    @Synchronized private fun writeBytes(chunk: ByteArray) {
        val held = output ?: throw MediaServiceException(MediaServiceFailure.RETIRED)
        held.write(chunk)
    }
    @Synchronized override fun close() { val held = output; output = null; held?.close() }
}
