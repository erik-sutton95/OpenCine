package com.opencapture.opencine.dji

import com.opencapture.opencine.media.*
import com.opencapture.opencine.vocabulary.MediaFile
import com.opencapture.opencine.vocabulary.MediaHTTP
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

public sealed class DJIMediaHTTPError : IOException() {
    public data object BadResponse : DJIMediaHTTPError()
    public data class HttpStatus(public val code: Int) : DJIMediaHTTPError()
    public data object Timeout : DJIMediaHTTPError()
}
public data class DJIMediaHTTPResource(public val storage: Int, public val url: String)

/** One source's raw storage routing and existing Android retry classification. */
public class DJIMediaHTTPSource {
    private val winners = mutableMapOf<String, Int>()
    public fun reset() { winners.clear() }
    public fun resolvedStorage(file: MediaFile, singleSDStorage: Boolean): Int = MediaHTTP.resolvedStorage(
        file.storage, if (file.handle != 0L) file.handle else file.cmdHandle, winners[file.path], singleSDStorage)
    public fun rememberStorage(storage: Int, path: String) { winners[path] = storage }
    public fun resources(path: String, firstStorage: Int): List<DJIMediaHTTPResource> =
        storageOrder(firstStorage).map { DJIMediaHTTPResource(it, MediaHTTP.pathUrlString(it, path)) }
    public fun transferPlan(file: MediaFile, path: String, singleSDStorage: Boolean,
        read: suspend (DJIMediaHTTPResource, Long?, MediaByteSink) -> MediaTransferReceipt): MediaTransferPlan {
        val resources = resources(path, resolvedStorage(file, singleSDStorage))
        val expected = file.sizeBytes.takeIf { path == file.path && it > 0 }
        val attempts: List<suspend (MediaByteSink) -> MediaTransferReceipt> = resources.map { resource ->
            attempt(resource, expected, read)
        }
        return MediaTransferPlan(expected, attempts, retry = ::retryDownload,
            accepted = { index, _ -> winners[file.path] = resources[index].storage })
    }
    private fun attempt(resource: DJIMediaHTTPResource, expected: Long?,
        read: suspend (DJIMediaHTTPResource, Long?, MediaByteSink) -> MediaTransferReceipt): suspend (MediaByteSink) -> MediaTransferReceipt =
        { sink -> read(resource, expected, sink) }
    public suspend fun read(path: String, firstStorage: Int, ifCurrent: () -> Boolean,
        read: suspend (DJIMediaHTTPResource) -> ByteArray): Pair<ByteArray, Int> {
        var last: Throwable = DJIMediaHTTPError.BadResponse
        for (resource in resources(path, firstStorage)) {
            currentCoroutineContext().ensureActive()
            if (!ifCurrent()) throw MediaServiceException(MediaServiceFailure.RETIRED)
            try {
                val bytes = read(resource)
                currentCoroutineContext().ensureActive()
                if (!ifCurrent()) throw MediaServiceException(MediaServiceFailure.RETIRED)
                if (bytes.isNotEmpty()) return bytes to resource.storage
                last = DJIMediaHTTPError.BadResponse
            } catch (error: DJIMediaHTTPError) {
                currentCoroutineContext().ensureActive()
                if (!ifCurrent()) throw MediaServiceException(MediaServiceFailure.RETIRED)
                if (!retryDownload(error)) throw error
                last = error
            }
        }
        throw last
    }
    public companion object {
        public fun storageOrder(first: Int): List<Int> = if (first == 0) listOf(0, 1) else listOf(1, 0)
        public fun retryDownload(error: Throwable): Boolean = when (error) {
            is CancellationException -> false
            is DJIMediaHTTPError.HttpStatus -> error.code == 404 || error.code in 400..499
            is DJIMediaHTTPError -> true
            else -> false
        }
    }
}
