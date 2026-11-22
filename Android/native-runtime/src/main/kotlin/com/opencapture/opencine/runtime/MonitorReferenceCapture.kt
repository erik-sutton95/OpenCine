package com.opencapture.opencine.runtime

import android.graphics.Bitmap
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

/** One bounded request on a picture owner. Producers only copy pixels while a request is active. */
class MonitorReferenceCapture<Frame : Any> {
    private class Request<Frame>(val accepts: (Long) -> Boolean) {
        val result = CompletableDeferred<Frame?>()
    }

    private val request = AtomicReference<Request<Frame>?>(null)

    suspend fun capture(accepts: (Long) -> Boolean = { true }, wake: () -> Unit = {}): Frame? {
        val next = Request<Frame>(accepts)
        if (!request.compareAndSet(null, next)) return null
        try {
            wake()
            return withTimeoutOrNull(1_500) { next.result.await() }
        } finally {
            request.compareAndSet(next, null)
        }
    }

    fun needsFrame(timestampNs: Long): Boolean = request.get()?.accepts?.invoke(timestampNs) == true

    fun offer(timestampNs: Long, copy: () -> Frame?) {
        val pending = request.get() ?: return
        if (!pending.accepts(timestampNs)) return
        val frame = copy()
        if (request.compareAndSet(pending, null)) pending.result.complete(frame)
    }

    fun cancel() {
        request.getAndSet(null)?.result?.complete(null)
    }
}

/** An owned, clean picture and its upright pre-viewport display geometry. */
data class MonitorReferenceFrame(
    val bitmap: Bitmap,
    val aspect: Float,
    val rotationDegrees: Int = 0,
)

/** Converts an identity readback and preserves its pre-viewport display shape. */
fun MonitorCleanPictureFrame.referenceFrame(displayAspect: Float = displayWidth.toFloat() / displayHeight): MonitorReferenceFrame {
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    if (bottomUp) {
        val topDown = ByteArray(width * height * 4)
        val stride = width * 4
        for (y in 0 until height) rgba.copyInto(topDown, y * stride, (height - 1 - y) * stride, (height - y) * stride)
        bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(topDown))
    } else {
        bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
    }
    return MonitorReferenceFrame(bitmap, displayAspect)
}
