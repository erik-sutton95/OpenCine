package com.opencapture.opencine.runtime

import com.opencapture.opencine.media.MediaByteSink
import com.opencapture.opencine.media.MediaTransferReceipt
import com.opencapture.opencine.media.MediaTransferProgressSink
import kotlinx.coroutines.*
import java.io.InputStream
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** The app's existing HTTP client owns socket construction. Cancellation must be idempotent and
 * interrupt a pending open/read; the shared worker owns bounded copying and completion. */
public interface MonitorMediaReadSource {
    public fun open(): MonitorMediaReadStream
    public fun cancel()
}
public interface MonitorMediaReadStream : AutoCloseable {
    public val status: Int?
    public val contentLength: Long?
    public val input: InputStream
}
public sealed class MonitorMediaStreamException(message: String) : IOException(message) {
    public class Status(public val status: Int) : MonitorMediaStreamException("HTTP $status")
    public class Empty : MonitorMediaStreamException("Empty media response")
    public class Limit : MonitorMediaStreamException("Media response exceeds the supplied limit")
}

/** Native streaming owner. Header length takes precedence over the source's optional size hint;
 * either ends a complete response without an extra blocking read. EOF may return a positive
 * partial receipt, separate from the cache's explicit original-size eligibility policy. */
public class MonitorMediaStreamPump(private val chunkBytes: Int = 64 * 1024) {
    init { require(chunkBytes > 0) }
    public suspend fun transfer(source: MonitorMediaReadSource, expectedByteCount: Long? = null,
        sink: MediaByteSink, maxByteCount: Long = Long.MAX_VALUE): MediaTransferReceipt = coroutineScope {
        require(maxByteCount > 0)
        suspendCancellableCoroutine { continuation ->
            val reader = launch(Dispatchers.IO) {
                try {
                    val receipt = copy(source, expectedByteCount, sink, maxByteCount)
                    currentCoroutineContext().ensureActive()
                    continuation.resume(receipt)
                } catch (error: Throwable) { continuation.resumeWithException(error) }
                finally { source.cancel() }
            }
            continuation.invokeOnCancellation { source.cancel(); reader.cancel() }
        }
    }
    private suspend fun copy(source: MonitorMediaReadSource, hint: Long?, sink: MediaByteSink,
        maximum: Long): MediaTransferReceipt {
        var written = 0L
        var expected: Long? = hint?.takeIf { it > 0 }
        try {
            source.open().use { stream ->
                currentCoroutineContext().ensureActive()
                stream.status?.let { if (it !in 200..299) throw MonitorMediaStreamException.Status(it) }
                expected = stream.contentLength?.takeIf { it > 0 } ?: expected
                if ((expected ?: 0) > maximum) throw MonitorMediaStreamException.Limit()
                (sink as? MediaTransferProgressSink)?.expectedByteCount(expected)
                val buffer = ByteArray(chunkBytes)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val remaining = expected?.let { (it - written).coerceAtLeast(0) } ?: Long.MAX_VALUE
                    if (remaining == 0L) break
                    val capacity = (maximum - written).coerceAtLeast(0)
                    if (capacity == 0L) {
                        if (stream.input.read() >= 0) throw MonitorMediaStreamException.Limit()
                        break
                    }
                    val count = stream.input.read(buffer, 0, minOf(remaining, capacity, buffer.size.toLong()).toInt())
                    currentCoroutineContext().ensureActive()
                    if (count < 0) break
                    if (count == 0) { yield(); continue }
                    sink.write(buffer.copyOf(count)); written += count
                    if (expected != null && written >= checkNotNull(expected)) break
                }
            }
        } catch (error: IOException) {
            currentCoroutineContext().ensureActive()
            // Preserve the existing driver's completion-at-length exception policy without
            // allowing an explicit cancellation or HTTP/limit refusal to become success.
            if (error is MonitorMediaStreamException || written <= 0 || expected == null || written < checkNotNull(expected)) throw error
        }
        currentCoroutineContext().ensureActive()
        if (written <= 0) throw MonitorMediaStreamException.Empty()
        return MediaTransferReceipt(written, expected)
    }
}
